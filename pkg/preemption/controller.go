package preemption

import (
	"context"

	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

var (
	workloadGVK = schema.GroupVersionKind{
		Group:   "kueue.x-k8s.io",
		Version: "v1beta1",
		Kind:    "Workload",
	}
	rayClusterGVK = schema.GroupVersionKind{
		Group:   "ray.io",
		Version: "v1",
		Kind:    "RayCluster",
	}
)

type Reconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	wl := &unstructured.Unstructured{}
	wl.SetGroupVersionKind(workloadGVK)
	if err := r.Get(ctx, req.NamespacedName, wl); err != nil {
		if errors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	annotations := wl.GetAnnotations()
	if annotations != nil && annotations["kueue.x-k8s.io/preemption-initiated"] == "true" {
		return ctrl.Result{}, nil
	}

	// Check if this is a high-priority pending workload waiting for quota
	priority, _, _ := unstructured.NestedInt64(wl.Object, "spec", "priority")
	if priority < 500 {
		return ctrl.Result{}, nil
	}

	isAdmitted := false
	conditions, _, _ := unstructured.NestedSlice(wl.Object, "status", "conditions")
	for _, c := range conditions {
		if cMap, ok := c.(map[string]interface{}); ok {
			if cMap["type"] == "Admitted" && cMap["status"] == "True" {
				isAdmitted = true
				break
			}
		}
	}
	if isAdmitted {
		return ctrl.Result{}, nil
	}

	queueName, _, _ := unstructured.NestedString(wl.Object, "spec", "queueName")
	if queueName == "" {
		return ctrl.Result{}, nil
	}

	neededGPUs := r.extractWorkloadGPUs(wl)
	if neededGPUs <= 0 {
		return ctrl.Result{}, nil
	}

	logger.Info("high priority workload pending quota, initiating collaborative partial preemption",
		"workload", wl.GetName(), "neededGPUs", neededGPUs, "queue", queueName)

	// Find victim RayClusters in the same namespace / queue
	rayList := &unstructured.UnstructuredList{}
	rayList.SetGroupVersionKind(rayClusterGVK)
	if err := r.List(ctx, rayList, client.InNamespace(wl.GetNamespace())); err != nil {
		return ctrl.Result{}, err
	}

	for _, rc := range rayList.Items {
		wgs, found, _ := unstructured.NestedSlice(rc.Object, "spec", "workerGroupSpecs")
		if !found || len(wgs) == 0 {
			continue
		}
		for i, wg := range wgs {
			wgMap, ok := wg.(map[string]interface{})
			if !ok {
				continue
			}
			replicas, _ := wgMap["replicas"].(int64)
			minReplicas, _ := wgMap["minReplicas"].(int64)
			if replicas > minReplicas && replicas-int64(neededGPUs) >= minReplicas {
				newReplicas := replicas - int64(neededGPUs)
				logger.Info("collaborative partial drain on victim RayCluster",
					"rayCluster", rc.GetName(), "from", replicas, "to", newReplicas)
				
				err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
					latest := &unstructured.Unstructured{}
					latest.SetGroupVersionKind(rayClusterGVK)
					if err := r.Get(ctx, client.ObjectKey{Namespace: rc.GetNamespace(), Name: rc.GetName()}, latest); err != nil {
						return err
					}
					latestWgs, _, _ := unstructured.NestedSlice(latest.Object, "spec", "workerGroupSpecs")
					latestWgMap := latestWgs[i].(map[string]interface{})
					latestWgMap["replicas"] = newReplicas
					latestWgs[i] = latestWgMap
					_ = unstructured.SetNestedSlice(latest.Object, latestWgs, "spec", "workerGroupSpecs")
					return r.Update(ctx, latest)
				})
				if err != nil {
					return ctrl.Result{}, err
				}
				
				// Mark preemption initiated on the preemptor workload to ensure idempotency
				_ = retry.RetryOnConflict(retry.DefaultRetry, func() error {
					latest := &unstructured.Unstructured{}
					latest.SetGroupVersionKind(workloadGVK)
					if err := r.Get(ctx, req.NamespacedName, latest); err != nil {
						return err
					}
					ann := latest.GetAnnotations()
					if ann == nil {
						ann = map[string]string{}
					}
					ann["kueue.x-k8s.io/preemption-initiated"] = "true"
					latest.SetAnnotations(ann)
					return r.Update(ctx, latest)
				})

				// Also update the victim RayCluster Workload podSet count so Kueue immediately reclaims quota
				r.updateRayWorkloadPodCount(ctx, rc.GetNamespace(), rc.GetName(), newReplicas)
				return ctrl.Result{}, nil
			}
		}
	}

	return ctrl.Result{}, nil
}

func (r *Reconciler) extractWorkloadGPUs(wl *unstructured.Unstructured) int {
	podSets, found, _ := unstructured.NestedSlice(wl.Object, "spec", "podSets")
	if !found {
		return 0
	}
	total := 0
	for _, ps := range podSets {
		psMap, ok := ps.(map[string]interface{})
		if !ok {
			continue
		}
		count, _ := psMap["count"].(int64)
		containers, _, _ := unstructured.NestedSlice(psMap, "template", "spec", "containers")
		for _, c := range containers {
			cMap, ok := c.(map[string]interface{})
			if !ok {
				continue
			}
			reqs, _, _ := unstructured.NestedMap(cMap, "resources", "requests")
			if reqs != nil && reqs["nvidia.com/gpu"] != nil {
				total += int(count)
			}
		}
	}
	return total
}

func (r *Reconciler) updateRayWorkloadPodCount(ctx context.Context, namespace, rayClusterName string, newWorkers int64) {
	wlList := &unstructured.UnstructuredList{}
	wlList.SetGroupVersionKind(workloadGVK)
	if err := r.List(ctx, wlList, client.InNamespace(namespace)); err != nil {
		return
	}
	for _, wl := range wlList.Items {
		owners, found, _ := unstructured.NestedSlice(wl.Object, "metadata", "ownerReferences")
		if !found {
			continue
		}
		isRay := false
		for _, o := range owners {
			oMap, ok := o.(map[string]interface{})
			if ok && oMap["kind"] == "RayCluster" && oMap["name"] == rayClusterName {
				isRay = true
				break
			}
		}
		if isRay {
			_ = retry.RetryOnConflict(retry.DefaultRetry, func() error {
				latest := &unstructured.Unstructured{}
				latest.SetGroupVersionKind(workloadGVK)
				if err := r.Get(ctx, client.ObjectKey{Namespace: namespace, Name: wl.GetName()}, latest); err != nil {
					return err
				}
				podSets, _, _ := unstructured.NestedSlice(latest.Object, "spec", "podSets")
				for i, ps := range podSets {
					psMap := ps.(map[string]interface{})
					if psMap["name"] == "workers" {
						psMap["count"] = newWorkers
						podSets[i] = psMap
					}
				}
				_ = unstructured.SetNestedSlice(latest.Object, podSets, "spec", "podSets")
				return r.Update(ctx, latest)
			})
			break
		}
	}
}

func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	wl := &unstructured.Unstructured{}
	wl.SetGroupVersionKind(workloadGVK)
	return ctrl.NewControllerManagedBy(mgr).
		Named("preemption").
		For(wl).
		Complete(r)
}
