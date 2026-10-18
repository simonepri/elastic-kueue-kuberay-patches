package scalegate

import (
	"context"
	"fmt"
	"math"

	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
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
		workerUnit := r.extractWorkerUnitResources(wgMap)
		maxAllowedQuota, err := r.resolveAvailableQuota(ctx, rc.GetNamespace(), queueName, workerUnit)
		if err != nil {
			logger.V(2).Info("could not resolve available quota for queue", "queue", queueName, "error", err)
			continue
		}

		targetLimit := int64(maxAllowedQuota)
		replicas, _ := wgMap["replicas"].(int64)
		maxReplicas, _ := wgMap["maxReplicas"].(int64)

		if maxReplicas > targetLimit {
			logger.Info("clamping RayCluster maxReplicas to Kueue quota",
				"cluster", rc.GetName(), "requestedMax", maxReplicas, "clamped", targetLimit)
			wgMap["maxReplicas"] = targetLimit
			clamped = true
		}
		if replicas > targetLimit {
			logger.Info("clamping RayCluster replicas to Kueue quota",
				"cluster", rc.GetName(), "requestedReplicas", replicas, "clamped", targetLimit)
			wgMap["replicas"] = targetLimit
			clamped = true
		}
		workerGroups[i] = wgMap
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
				workerUnit := r.extractWorkerUnitResources(wgMap)
				maxAllowedQuota, qErr := r.resolveAvailableQuota(ctx, rc.GetNamespace(), queueName, workerUnit)
				if qErr != nil {
					continue
				}
				targetLimit := int64(maxAllowedQuota)
				replicas, _ := wgMap["replicas"].(int64)
				maxReplicas, _ := wgMap["maxReplicas"].(int64)
				if maxReplicas > targetLimit {
					wgMap["maxReplicas"] = targetLimit
				}
				if replicas > targetLimit {
					wgMap["replicas"] = targetLimit
				}
				wgs[i] = wgMap
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
			filteredConditions := []interface{}{}
			for _, cond := range conditions {
				if cMap, ok := cond.(map[string]interface{}); ok {
					if cMap["type"] != "ScaleGateClamped" {
						filteredConditions = append(filteredConditions, cond)
					}
				}
			}
			filteredConditions = append(filteredConditions, map[string]interface{}{
				"type":               "ScaleGateClamped",
				"status":             "True",
				"reason":             "KueueQuotaCapped",
				"message":            "Worker replicas and maxReplicas clamped to available Kueue ClusterQueue quota",
				"lastTransitionTime": metav1.Now().UTC().Format("2006-01-02T15:04:05Z"),
			})
			_ = unstructured.SetNestedSlice(latest.Object, filteredConditions, "status", "conditions")
			return r.Status().Update(ctx, latest)
		})
	}

	return ctrl.Result{}, nil
}

func (r *Reconciler) extractWorkerUnitResources(wgMap map[string]interface{}) map[string]int64 {
	unit := make(map[string]int64)
	containers, _, _ := unstructured.NestedSlice(wgMap, "template", "spec", "containers")
	for _, c := range containers {
		cMap, ok := c.(map[string]interface{})
		if !ok {
			continue
		}
		reqs, _, _ := unstructured.NestedMap(cMap, "resources", "requests")
		if reqs == nil {
			continue
		}
		for resName, val := range reqs {
			var amount int64
			if s, ok := val.(string); ok {
				q, err := resource.ParseQuantity(s)
				if err == nil {
					if resName == "cpu" {
						amount = q.MilliValue()
					} else {
						amount = q.Value()
					}
				}
			} else if num, ok := val.(int64); ok {
				amount = num
			}
			if amount > 0 {
				unit[resName] += amount
			}
		}
	}
	return unit
}

func (r *Reconciler) parseResourceValue(resName string, raw interface{}) int64 {
	if raw == nil {
		return 0
	}
	s := fmt.Sprint(raw)
	q, err := resource.ParseQuantity(s)
	if err == nil {
		if resName == "cpu" {
			return q.MilliValue()
		}
		return q.Value()
	}
	var num int64
	_, _ = fmt.Sscanf(s, "%d", &num)
	return num
}

func (r *Reconciler) resolveAvailableQuota(ctx context.Context, namespace, queueName string, workerUnit map[string]int64) (int, error) {
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

	cohort, _, _ := unstructured.NestedString(cq.Object, "spec", "cohort")
	rGroups, found, _ := unstructured.NestedSlice(cq.Object, "spec", "resourceGroups")
	if !found {
		return 4, nil
	}

	minAllowedReplicas := int64(math.MaxInt64)
	matchedAnyResource := false

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
				resName, _ := resMap["name"].(string)
				nominalVal := r.parseResourceValue(resName, resMap["nominalQuota"])
				totalLimit := nominalVal
				if cohort != "" && resMap["borrowingLimit"] != nil {
					borrowVal := r.parseResourceValue(resName, resMap["borrowingLimit"])
					if borrowVal > 0 {
						totalLimit += borrowVal
					}
				}

				if totalLimit <= 0 {
					continue
				}

				// If worker requests this resource specifically (GPU, CPU, Memory, etc.)
				if reqVal, ok := workerUnit[resName]; ok && reqVal > 0 {
					replicasForRes := totalLimit / reqVal
					if replicasForRes < minAllowedReplicas {
						minAllowedReplicas = replicasForRes
					}
					matchedAnyResource = true
				} else if len(workerUnit) == 0 {
					// Fallback if no worker requests defined: treat 1 unit = 1 replica
					if totalLimit < minAllowedReplicas {
						minAllowedReplicas = totalLimit
					}
					matchedAnyResource = true
				}
			}
		}
	}

	if matchedAnyResource && minAllowedReplicas != math.MaxInt64 && minAllowedReplicas > 0 {
		return int(minAllowedReplicas), nil
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
