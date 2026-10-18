package preemption

import (
	"context"
	"fmt"
	"time"

	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
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
	priorityClassGVK = schema.GroupVersionKind{
		Group:   "scheduling.k8s.io",
		Version: "v1",
		Kind:    "PriorityClass",
	}
	workloadPriorityClassGVK = schema.GroupVersionKind{
		Group:   "kueue.x-k8s.io",
		Version: "v1beta1",
		Kind:    "WorkloadPriorityClass",
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

	// Workload must be pending admission
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

	preemptorPriority := r.getWorkloadPriority(ctx, wl)
	workloadDemands := r.extractWorkloadDemands(wl)
	if len(workloadDemands) == 0 {
		return ctrl.Result{}, nil
	}

	logger.Info("pending workload evaluating collaborative preemption & fair sharing",
		"workload", wl.GetName(), "priority", preemptorPriority, "queue", queueName, "namespace", wl.GetNamespace())

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

			workerUnit := r.extractWorkerUnitResources(wgMap)
			victimPriority := r.getRayClusterPriority(ctx, &rc)
			victimQueue := rc.GetLabels()["kueue.x-k8s.io/queue-name"]

			var reclaimAmount int64
			reason := ""
			bottleneckRes := ""

			isCrossQueue := (queueName != victimQueue)

			if isCrossQueue {
				// Cohort Borrowing Reclaim:
				// Evaluate each demanded resource independently.
				// If the victim is borrowing above its queues nominal quota on resource r,
				// calculate the borrowed excess in worker units.
				for resName, demandVal := range workloadDemands {
					unitVal, ok := workerUnit[resName]
					if !ok || unitVal <= 0 {
						continue
					}
					neededForRes := (demandVal + unitVal - 1) / unitVal
					nominalForRes := r.getNominalQuota(ctx, rc.GetNamespace(), victimQueue, resName, unitVal)
					if replicas > nominalForRes {
						borrowed := replicas - nominalForRes
						reclaimForRes := borrowed
						if neededForRes < borrowed {
							reclaimForRes = neededForRes
						}
						if reclaimForRes > reclaimAmount {
							reclaimAmount = reclaimForRes
							bottleneckRes = resName
							reason = "cohort-reclaim"
						}
					}
				}
				if reclaimAmount <= 0 {
					continue
				}
			} else {
				// Intra-Queue Evaluation:
				neededWorkers, bRes := r.calculateNeededWorkers(workloadDemands, workerUnit)
				if neededWorkers <= 0 {
					continue
				}
				bottleneckRes = bRes
				workerUnitAmount := workerUnit[bottleneckRes]
				nominalQuota := r.getNominalQuota(ctx, rc.GetNamespace(), victimQueue, bottleneckRes, workerUnitAmount)

				if preemptorPriority > victimPriority {
					// Strict Priority Preemption
					reclaimAmount = neededWorkers
					reason = "priority-preemption"
				} else if preemptorPriority == victimPriority {
					// Fair Sharing among equals:
					// Total nominal quota in the queue is shared equally among active/pending pipelines
					fairShare := nominalQuota / 2
					if fairShare < minReplicas {
						fairShare = minReplicas
					}
					if replicas > fairShare {
						excess := replicas - fairShare
						if neededWorkers < excess {
							reclaimAmount = neededWorkers
						} else {
							reclaimAmount = excess
						}
						reason = "fair-share"
					} else {
						continue
					}
				} else {
					// Lower priority cannot preempt higher priority
					continue
				}
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
				"rayCluster", rc.GetName(), "from", replicas, "to", newReplicas, "resource", bottleneckRes, "reason", reason)

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

func (r *Reconciler) getWorkloadPriority(ctx context.Context, wl *unstructured.Unstructured) int64 {
	p, found, _ := unstructured.NestedInt64(wl.Object, "spec", "priority")
	if found {
		return p
	}
	pClassName, found, _ := unstructured.NestedString(wl.Object, "spec", "priorityClassName")
	if found && pClassName != "" {
		return r.resolvePriorityValue(ctx, pClassName)
	}
	return 0
}

func (r *Reconciler) getRayClusterPriority(ctx context.Context, rc *unstructured.Unstructured) int64 {
	wlList := &unstructured.UnstructuredList{}
	wlList.SetGroupVersionKind(workloadGVK)
	if err := r.List(ctx, wlList, client.InNamespace(rc.GetNamespace())); err == nil {
		for _, wl := range wlList.Items {
			owners, found, _ := unstructured.NestedSlice(wl.Object, "metadata", "ownerReferences")
			if !found {
				continue
			}
			for _, o := range owners {
				if oMap, ok := o.(map[string]interface{}); ok && oMap["kind"] == "RayCluster" && oMap["name"] == rc.GetName() {
					return r.getWorkloadPriority(ctx, &wl)
				}
			}
		}
	}

	if pClass := rc.GetLabels()["kueue.x-k8s.io/priority-class"]; pClass != "" {
		return r.resolvePriorityValue(ctx, pClass)
	}

	wgs, found, _ := unstructured.NestedSlice(rc.Object, "spec", "workerGroupSpecs")
	if found && len(wgs) > 0 {
		if wgMap, ok := wgs[0].(map[string]interface{}); ok {
			pClass, _, _ := unstructured.NestedString(wgMap, "template", "spec", "priorityClassName")
			if pClass != "" {
				return r.resolvePriorityValue(ctx, pClass)
			}
		}
	}
	return 0
}

func (r *Reconciler) resolvePriorityValue(ctx context.Context, name string) int64 {
	wpc := &unstructured.Unstructured{}
	wpc.SetGroupVersionKind(workloadPriorityClassGVK)
	if err := r.Get(ctx, client.ObjectKey{Name: name}, wpc); err == nil {
		val, found, _ := unstructured.NestedInt64(wpc.Object, "value")
		if found {
			return val
		}
	}

	pc := &unstructured.Unstructured{}
	pc.SetGroupVersionKind(priorityClassGVK)
	if err := r.Get(ctx, client.ObjectKey{Name: name}, pc); err == nil {
		val, found, _ := unstructured.NestedInt64(pc.Object, "value")
		if found {
			return val
		}
	}
	return 0
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
	if len(unit) == 0 {
		unit["workers"] = 1
	}
	return unit
}

func (r *Reconciler) extractWorkloadDemands(wl *unstructured.Unstructured) map[string]int64 {
	podSets, found, _ := unstructured.NestedSlice(wl.Object, "spec", "podSets")
	if !found {
		return nil
	}
	demands := make(map[string]int64)
	for _, ps := range podSets {
		psMap, ok := ps.(map[string]interface{})
		if !ok {
			continue
		}
		count, _ := psMap["count"].(int64)
		if count <= 0 {
			count = 1
		}
		containers, _, _ := unstructured.NestedSlice(psMap, "template", "spec", "containers")
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
					demands[resName] += amount * count
				}
			}
		}
	}
	if len(demands) == 0 {
		demands["workers"] = 1
	}
	return demands
}

func (r *Reconciler) calculateNeededWorkers(demands, workerUnit map[string]int64) (int64, string) {
	maxWorkers := int64(0)
	bottleneck := "workers"

	for resName, demandVal := range demands {
		if unitVal, ok := workerUnit[resName]; ok && unitVal > 0 {
			w := (demandVal + unitVal - 1) / unitVal
			if w > maxWorkers {
				maxWorkers = w
				bottleneck = resName
			}
		}
	}

	if maxWorkers == 0 {
		if d, ok := demands["workers"]; ok {
			return d, "workers"
		}
		return 1, "workers"
	}
	return maxWorkers, bottleneck
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

func (r *Reconciler) getNominalQuota(ctx context.Context, namespace, queueName, resName string, workerUnitAmount int64) int64 {
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
				name, _ := resMap["name"].(string)
				if name == resName || resName == "workers" {
					nominal := r.parseResourceValue(name, resMap["nominalQuota"])
					if workerUnitAmount > 0 {
						return nominal / workerUnitAmount
					}
					if nominal > 0 {
						return nominal
					}
				}
			}
		}
	}
	return 4
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
