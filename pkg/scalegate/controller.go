package scalegate

import (
	"context"
	"fmt"

	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

var (
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

	rc := &unstructured.Unstructured{}
	rc.SetGroupVersionKind(rayClusterGVK)
	if err := r.Get(ctx, req.NamespacedName, rc); err != nil {
		if errors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	queueName := rc.GetLabels()["kueue.x-k8s.io/queue-name"]
	if queueName == "" {
		return ctrl.Result{}, nil
	}

	maxAllowedQuota, err := r.resolveAvailableQuota(ctx, rc.GetNamespace(), queueName)
	if err != nil {
		logger.V(2).Info("could not resolve available quota for queue", "queue", queueName, "error", err)
		return ctrl.Result{}, nil
	}

	workerGroups, found, err := unstructured.NestedSlice(rc.Object, "spec", "workerGroupSpecs")
	if !found || err != nil || len(workerGroups) == 0 {
		return ctrl.Result{}, nil
	}

	clamped := false
	for i, wg := range workerGroups {
		wgMap, ok := wg.(map[string]interface{})
		if !ok {
			continue
		}
		replicas, _ := wgMap["replicas"].(int64)
		if replicas > int64(maxAllowedQuota) {
			logger.Info("clamping RayCluster replicas to Kueue quota",
				"cluster", rc.GetName(), "requested", replicas, "clamped", maxAllowedQuota)
			wgMap["replicas"] = int64(maxAllowedQuota)
			workerGroups[i] = wgMap
			clamped = true
		}
	}

	if clamped {
		err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
			latest := &unstructured.Unstructured{}
			latest.SetGroupVersionKind(rayClusterGVK)
			if err := r.Get(ctx, req.NamespacedName, latest); err != nil {
				return err
			}
			wgs, _, _ := unstructured.NestedSlice(latest.Object, "spec", "workerGroupSpecs")
			for i, wg := range wgs {
				wgMap, ok := wg.(map[string]interface{})
				if !ok {
					continue
				}
				replicas, _ := wgMap["replicas"].(int64)
				if replicas > int64(maxAllowedQuota) {
					wgMap["replicas"] = int64(maxAllowedQuota)
					wgs[i] = wgMap
				}
			}
			_ = unstructured.SetNestedSlice(latest.Object, wgs, "spec", "workerGroupSpecs")
			return r.Update(ctx, latest)
		})
		if err != nil {
			return ctrl.Result{}, err
		}

		_ = retry.RetryOnConflict(retry.DefaultRetry, func() error {
			latest := &unstructured.Unstructured{}
			latest.SetGroupVersionKind(rayClusterGVK)
			if err := r.Get(ctx, req.NamespacedName, latest); err != nil {
				return err
			}
			conditions, _, _ := unstructured.NestedSlice(latest.Object, "status", "conditions")
			conditions = append(conditions, map[string]interface{}{
				"type":               "ScaleGateClamped",
				"status":             "True",
				"reason":             "KueueQuotaCapped",
				"message":            "Worker replicas clamped to available Kueue ClusterQueue quota",
				"lastTransitionTime": metav1.Now().UTC().Format("2006-01-02T15:04:05Z"),
			})
			_ = unstructured.SetNestedSlice(latest.Object, conditions, "status", "conditions")
			return r.Status().Update(ctx, latest)
		})
	}

	return ctrl.Result{}, nil
}

func (r *Reconciler) resolveAvailableQuota(ctx context.Context, namespace, queueName string) (int, error) {
	cq := &unstructured.Unstructured{}
	cq.SetGroupVersionKind(clusterQueueGVK)
	// Try getting ClusterQueue directly or resolve via LocalQueue
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

	cohort, _, _ := unstructured.NestedString(cq.Object, "spec", "cohort")

	// Extract nominal quota and borrowingLimit
	rGroups, found, _ := unstructured.NestedSlice(cq.Object, "spec", "resourceGroups")
	if !found {
		return 4, nil // fallback safe default
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
					nominalStr := fmt.Sprint(resMap["nominalQuota"])
					var nominal int
					_, _ = fmt.Sscanf(nominalStr, "%d", &nominal)

					totalLimit := nominal
					if cohort != "" && resMap["borrowingLimit"] != nil {
						borrowStr := fmt.Sprint(resMap["borrowingLimit"])
						var borrow int
						if _, err := fmt.Sscanf(borrowStr, "%d", &borrow); err == nil && borrow > 0 {
							totalLimit += borrow
						}
					}
					if totalLimit > 0 {
						return totalLimit, nil
					}
					return 4, nil
				}
			}
		}
	}
	return 4, nil
}

func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	rc := &unstructured.Unstructured{}
	rc.SetGroupVersionKind(rayClusterGVK)
	return ctrl.NewControllerManagedBy(mgr).
		Named("scalegate").
		For(rc).
		Complete(r)
}
