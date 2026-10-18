package preemption

import (
	"context"
	"fmt"
	"time"

	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

const (
	AnnotationPreemptionInitiated = "kyield.io/preemption-initiated"
	AnnotationPreemptedBy         = "kyield.io/preempted-by"
	AnnotationPreemptedByNs       = "kyield.io/preempted-by-ns"
	AnnotationOriginalReplicas    = "kyield.io/original-replicas"
	AnnotationOriginalMaxReplicas = "kyield.io/original-max-replicas"
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
	clusterQueueGVK = schema.GroupVersionKind{
		Group:   "kueue.x-k8s.io",
		Version: "v1beta1",
		Kind:    "ClusterQueue",
	}
	localQueueGVK = schema.GroupVersionKind{
		Group:   "kueue.x-k8s.io",
		Version: "v1beta1",
		Kind:    "LocalQueue",
	}
)

type Reconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// Phase 1: Reconcile re-expansion for any RayCluster whose preemptor has finished or exited
	hasPendingReexpansion := r.reconcileRayReexpansion(ctx)

	// Phase 2: Check Workload preemption
	wl := &unstructured.Unstructured{}
	wl.SetGroupVersionKind(workloadGVK)
	if err := r.Get(ctx, req.NamespacedName, wl); err != nil {
		if errors.IsNotFound(err) {
			if hasPendingReexpansion {
				return ctrl.Result{RequeueAfter: 1 * time.Second}, nil
			}
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	annotations := wl.GetAnnotations()
	if annotations != nil && annotations[AnnotationPreemptionInitiated] == "true" {
		if hasPendingReexpansion {
			return ctrl.Result{RequeueAfter: 1 * time.Second}, nil
		}
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

	logger.Info("high priority workload pending quota, evaluating collaborative preemption",
		"workload", wl.GetName(), "neededGPUs", neededGPUs, "queue", queueName, "namespace", wl.GetNamespace())

	// List candidate RayClusters in the same namespace
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
			maxReplicas, _ := wgMap["maxReplicas"].(int64)
			minReplicas, _ := wgMap["minReplicas"].(int64)
			if minReplicas == 0 {
				minReplicas = 1
			}

			// Determine reclaim amount based on cohort borrowing vs local queue
			victimQueue := rc.GetLabels()["kueue.x-k8s.io/queue-name"]
			nominalQuota := int64(r.getNominalQuota(ctx, rc.GetNamespace(), victimQueue))

			var reclaimAmount int64
			if replicas > nominalQuota {
				borrowed := replicas - nominalQuota
				if int64(neededGPUs) < borrowed {
					reclaimAmount = int64(neededGPUs)
				} else {
					reclaimAmount = borrowed
				}
			} else {
				reclaimAmount = int64(neededGPUs)
			}

			if reclaimAmount <= 0 {
				continue
			}

			// Check if downscale would violate minReplicas threshold
			if replicas-reclaimAmount < minReplicas {
				logger.Info("partial preemption would violate minReplicas threshold; refusing partial drain",
					"rayCluster", rc.GetName(), "current", replicas, "reclaim", reclaimAmount, "minReplicas", minReplicas)
				_ = r.publishCondition(ctx, rc.GetNamespace(), rc.GetName(), "PartialPreemptionRefused", "True", "BelowMinViableReplicas", "Partial preemption would violate minReplicas threshold")
				continue
			}

			newReplicas := replicas - reclaimAmount
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
				latestWgMap["maxReplicas"] = newReplicas
				latestWgs[i] = latestWgMap
				_ = unstructured.SetNestedSlice(latest.Object, latestWgs, "spec", "workerGroupSpecs")

				// Save preemption metadata under kyield.io domain
				ann := latest.GetAnnotations()
				if ann == nil {
					ann = map[string]string{}
				}
				ann[AnnotationPreemptedBy] = wl.GetName()
				ann[AnnotationPreemptedByNs] = wl.GetNamespace()
				ann[AnnotationOriginalReplicas] = fmt.Sprint(replicas)
				ann[AnnotationOriginalMaxReplicas] = fmt.Sprint(maxReplicas)
				latest.SetAnnotations(ann)

				return r.Update(ctx, latest)
			})
			if err != nil {
				return ctrl.Result{}, err
			}

			// Mark preemption initiated on the preemptor workload
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
				ann[AnnotationPreemptionInitiated] = "true"
				latest.SetAnnotations(ann)
				return r.Update(ctx, latest)
			})

			r.updateRayWorkloadPodCount(ctx, rc.GetNamespace(), rc.GetName(), newReplicas)
			return ctrl.Result{RequeueAfter: 1 * time.Second}, nil
		}
	}

	if hasPendingReexpansion {
		return ctrl.Result{RequeueAfter: 1 * time.Second}, nil
	}
	return ctrl.Result{}, nil
}

func (r *Reconciler) reconcileRayReexpansion(ctx context.Context) bool {
	logger := log.FromContext(ctx)
	rayList := &unstructured.UnstructuredList{}
	rayList.SetGroupVersionKind(rayClusterGVK)
	if err := r.List(ctx, rayList); err != nil {
		return false
	}

	hasTracked := false
	for _, rc := range rayList.Items {
		ann := rc.GetAnnotations()
		if ann == nil || ann[AnnotationPreemptedBy] == "" {
			continue
		}
		hasTracked = true
		preemptorName := ann[AnnotationPreemptedBy]
		preemptorNs := ann[AnnotationPreemptedByNs]
		if preemptorNs == "" {
			preemptorNs = rc.GetNamespace()
		}

		preemptorWL := &unstructured.Unstructured{}
		preemptorWL.SetGroupVersionKind(workloadGVK)
		err := r.Get(ctx, client.ObjectKey{Namespace: preemptorNs, Name: preemptorName}, preemptorWL)

		shouldReexpand := false
		if errors.IsNotFound(err) {
			shouldReexpand = true
		} else if err == nil {
			conditions, _, _ := unstructured.NestedSlice(preemptorWL.Object, "status", "conditions")
			for _, c := range conditions {
				if cMap, ok := c.(map[string]interface{}); ok {
					if cMap["type"] == "Finished" && cMap["status"] == "True" {
						shouldReexpand = true
						break
					}
				}
			}
		}

		if shouldReexpand {
			var origReplicas int64
			_, _ = fmt.Sscanf(ann[AnnotationOriginalReplicas], "%d", &origReplicas)
			if origReplicas <= 0 {
				origReplicas = 8
			}
			var origMaxReplicas int64
			_, _ = fmt.Sscanf(ann[AnnotationOriginalMaxReplicas], "%d", &origMaxReplicas)
			if origMaxReplicas <= 0 {
				origMaxReplicas = origReplicas
			}

			logger.Info("preemptor workload no longer consuming quota; re-expanding RayCluster",
				"rayCluster", rc.GetName(), "targetReplicas", origReplicas)

			_ = retry.RetryOnConflict(retry.DefaultRetry, func() error {
				latest := &unstructured.Unstructured{}
				latest.SetGroupVersionKind(rayClusterGVK)
				if err := r.Get(ctx, client.ObjectKey{Namespace: rc.GetNamespace(), Name: rc.GetName()}, latest); err != nil {
					return err
				}
				latestWgs, _, _ := unstructured.NestedSlice(latest.Object, "spec", "workerGroupSpecs")
				if len(latestWgs) > 0 {
					latestWgMap := latestWgs[0].(map[string]interface{})
					latestWgMap["replicas"] = origReplicas
					latestWgMap["maxReplicas"] = origMaxReplicas
					latestWgs[0] = latestWgMap
					_ = unstructured.SetNestedSlice(latest.Object, latestWgs, "spec", "workerGroupSpecs")
				}
				latestAnn := latest.GetAnnotations()
				delete(latestAnn, AnnotationPreemptedBy)
				delete(latestAnn, AnnotationPreemptedByNs)
				delete(latestAnn, AnnotationOriginalReplicas)
				delete(latestAnn, AnnotationOriginalMaxReplicas)
				latest.SetAnnotations(latestAnn)
				return r.Update(ctx, latest)
			})

			r.updateRayWorkloadPodCount(ctx, rc.GetNamespace(), rc.GetName(), origReplicas)
		}
	}
	return hasTracked
}

func (r *Reconciler) getNominalQuota(ctx context.Context, namespace, queueName string) int {
	cq := &unstructured.Unstructured{}
	cq.SetGroupVersionKind(clusterQueueGVK)
	if err := r.Get(ctx, client.ObjectKey{Name: queueName}, cq); err != nil {
		lq := &unstructured.Unstructured{}
		lq.SetGroupVersionKind(localQueueGVK)
		if errLq := r.Get(ctx, client.ObjectKey{Namespace: namespace, Name: queueName}, lq); errLq == nil {
			targetCq, _, _ := unstructured.NestedString(lq.Object, "spec", "clusterQueue")
			if targetCq != "" {
				_ = r.Get(ctx, client.ObjectKey{Name: targetCq}, cq)
			}
		}
	}
	rGroups, found, _ := unstructured.NestedSlice(cq.Object, "spec", "resourceGroups")
	if !found {
		return 4
	}
	for _, rg := range rGroups {
		rgMap, ok := rg.(map[string]interface{})
		if !ok {
			continue
		}
		flavors, _, _ := unstructured.NestedSlice(rgMap, "flavors")
		for _, fl := range flavors {
			flMap, ok := fl.(map[string]interface{})
			if !ok {
				continue
			}
			resources, _, _ := unstructured.NestedSlice(flMap, "resources")
			for _, res := range resources {
				resMap, ok := res.(map[string]interface{})
				if !ok {
					continue
				}
				if resMap["name"] == "nvidia.com/gpu" {
					var nominal int
					_, _ = fmt.Sscanf(fmt.Sprint(resMap["nominalQuota"]), "%d", &nominal)
					if nominal > 0 {
						return nominal
					}
				}
			}
		}
	}
	return 4
}

func (r *Reconciler) publishCondition(ctx context.Context, namespace, name, condType, status, reason, message string) error {
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		latest := &unstructured.Unstructured{}
		latest.SetGroupVersionKind(rayClusterGVK)
		if err := r.Get(ctx, client.ObjectKey{Namespace: namespace, Name: name}, latest); err != nil {
			return err
		}
		conditions, _, _ := unstructured.NestedSlice(latest.Object, "status", "conditions")
		filtered := []interface{}{}
		for _, cond := range conditions {
			if cMap, ok := cond.(map[string]interface{}); ok {
				if cMap["type"] != condType {
					filtered = append(filtered, cond)
				}
			}
		}
		filtered = append(filtered, map[string]interface{}{
			"type":               condType,
			"status":             status,
			"reason":             reason,
			"message":            message,
			"lastTransitionTime": metav1.Now().UTC().Format("2006-01-02T15:04:05Z"),
		})
		_ = unstructured.SetNestedSlice(latest.Object, filtered, "status", "conditions")
		return r.Status().Update(ctx, latest)
	})
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
	rc := &unstructured.Unstructured{}
	rc.SetGroupVersionKind(rayClusterGVK)

	return ctrl.NewControllerManagedBy(mgr).
		Named("preemption").
		For(wl).
		Watches(rc, handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []ctrl.Request {
			return []ctrl.Request{{NamespacedName: client.ObjectKey{Namespace: obj.GetNamespace(), Name: obj.GetName()}}}
		})).
		Complete(r)
}
