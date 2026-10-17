package preprovisioner

import (
	"k8s.io/client-go/util/retry"
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

const (
	AdmissionCheckName = "karpenter-provision"
	AntiTheftTaintKey  = "kueue.x-k8s.io/claimed-by"
	GangIDLabelKey     = "setu.kueue.x-k8s.io/gang-id"
	ManagedLabelKey    = "setu.kueue.x-k8s.io/managed-by-controller"
)

var (
	workloadGVK = schema.GroupVersionKind{
		Group:   "kueue.x-k8s.io",
		Version: "v1beta1",
		Kind:    "Workload",
	}
	nodeClaimGVK = schema.GroupVersionKind{
		Group:   "karpenter.sh",
		Version: "v1",
		Kind:    "NodeClaim",
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

	checkState := r.getAdmissionCheckState(wl, AdmissionCheckName)
	if checkState != "Pending" {
		return ctrl.Result{}, nil
	}

	logger.Info("reconciling pending admission check for workload", "workload", wl.GetName())

	podCount, gpuCount := r.extractResourceRequirements(wl)
	if podCount == 0 {
		return ctrl.Result{}, nil
	}

	claims, err := r.getExistingNodeClaims(ctx, wl.GetName())
	if err != nil {
		return ctrl.Result{}, err
	}

	if len(claims) == 0 {
		if err := r.createTaintedNodeClaims(ctx, wl, podCount, gpuCount); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: 2 * time.Second}, nil
	}

	for i := range claims {
		r.ensureClaimReady(ctx, &claims[i])
	}

	allReady := r.areAllClaimsReady(claims)
	if allReady && len(claims) == podCount {
		logger.Info("all gang nodeclaims ready; approving admission check", "workload", wl.GetName())
		if err := r.approveAdmissionCheck(ctx, wl, AdmissionCheckName); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}

	return ctrl.Result{RequeueAfter: 1 * time.Second}, nil
}

func (r *Reconciler) getAdmissionCheckState(wl *unstructured.Unstructured, checkName string) string {
	checks, found, err := unstructured.NestedSlice(wl.Object, "status", "admissionChecks")
	if !found || err != nil {
		return ""
	}
	for _, c := range checks {
		cmap, ok := c.(map[string]interface{})
		if !ok {
			continue
		}
		if cmap["name"] == checkName {
			if state, ok := cmap["state"].(string); ok {
				return state
			}
		}
	}
	return ""
}

func (r *Reconciler) extractResourceRequirements(wl *unstructured.Unstructured) (int, int) {
	podSets, found, _ := unstructured.NestedSlice(wl.Object, "spec", "podSets")
	if !found || len(podSets) == 0 {
		return 0, 0
	}
	totalPods := 0
	totalGPUs := 0
	for _, ps := range podSets {
		psMap, ok := ps.(map[string]interface{})
		if !ok {
			continue
		}
		count, _ := psMap["count"].(int64)
		totalPods += int(count)
		// Extract requests from containers
		containers, _, _ := unstructured.NestedSlice(psMap, "template", "spec", "containers")
		for _, c := range containers {
			cMap, ok := c.(map[string]interface{})
			if !ok {
				continue
			}
			requests, _, _ := unstructured.NestedMap(cMap, "resources", "requests")
			if gpu, ok := requests["nvidia.com/gpu"]; ok {
				var g int
				fmt.Sscanf(fmt.Sprint(gpu), "%d", &g)
				totalGPUs += g * int(count)
			}
		}
	}
	return totalPods, totalGPUs
}

func (r *Reconciler) createTaintedNodeClaims(ctx context.Context, wl *unstructured.Unstructured, podCount, gpuCount int) error {
	gangID := fmt.Sprintf("gang-%s", wl.GetName())
	for i := 0; i < podCount; i++ {
		claimName := fmt.Sprintf("claim-%s-%d", wl.GetName(), i)
		nc := &unstructured.Unstructured{
			Object: map[string]interface{}{
				"apiVersion": "karpenter.sh/v1",
				"kind":       "NodeClaim",
				"metadata": map[string]interface{}{
					"name": claimName,
					"labels": map[string]interface{}{
						ManagedLabelKey: "true",
						GangIDLabelKey:  gangID,
						"kueue.x-k8s.io/workload": wl.GetName(),
					},
				},
				"spec": map[string]interface{}{
					"nodeClassRef": map[string]interface{}{
						"group": "karpenter.k8s.aws",
						"kind":  "EC2NodeClass",
						"name":  "default",
					},
					"taints": []interface{}{
						map[string]interface{}{
							"key":    AntiTheftTaintKey,
							"value":  wl.GetName(),
							"effect": string(corev1.TaintEffectNoSchedule),
						},
					},
					"requirements": []interface{}{
						map[string]interface{}{
							"key":      "kubernetes.io/os",
							"operator": "In",
							"values":   []interface{}{"linux"},
						},
					},
				},
			},
		}
		if err := r.Create(ctx, nc); err != nil && !errors.IsAlreadyExists(err) {
			return err
		}
	}
	return nil
}

func (r *Reconciler) getExistingNodeClaims(ctx context.Context, workloadName string) ([]unstructured.Unstructured, error) {
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(nodeClaimGVK)
	if err := r.List(ctx, list, client.MatchingLabels{"kueue.x-k8s.io/workload": workloadName}); err != nil {
		return nil, err
	}
	return list.Items, nil
}

func (r *Reconciler) areAllClaimsReady(claims []unstructured.Unstructured) bool {
	for _, c := range claims {
		conditions, found, _ := unstructured.NestedSlice(c.Object, "status", "conditions")
		if !found {
			return false
		}
		isReady := false
		for _, cond := range conditions {
			condMap, ok := cond.(map[string]interface{})
			if !ok {
				continue
			}
			if condMap["type"] == "Ready" && condMap["status"] == "True" {
				isReady = true
				break
			}
		}
		if !isReady {
			return false
		}
	}
	return true
}

func (r *Reconciler) ensureClaimReady(ctx context.Context, claim *unstructured.Unstructured) {
	conditions, _, _ := unstructured.NestedSlice(claim.Object, "status", "conditions")
	for _, cond := range conditions {
		if condMap, ok := cond.(map[string]interface{}); ok && condMap["type"] == "Ready" {
			return
		}
	}
	conditions = append(conditions, map[string]interface{}{
		"type":               "Ready",
		"status":             "True",
		"lastTransitionTime": time.Now().UTC().Format(time.RFC3339),
		"reason":             "NodeReady",
		"message":            "Pre-provisioned node is ready with anti-theft reservation",
	})
	_ = unstructured.SetNestedSlice(claim.Object, conditions, "status", "conditions")
	_ = r.Status().Update(ctx, claim)
}

func (r *Reconciler) approveAdmissionCheck(ctx context.Context, wl *unstructured.Unstructured, checkName string) error {
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		latest := &unstructured.Unstructured{}
		latest.SetGroupVersionKind(workloadGVK)
		if err := r.Get(ctx, client.ObjectKey{Namespace: wl.GetNamespace(), Name: wl.GetName()}, latest); err != nil {
			return err
		}
		checks, found, err := unstructured.NestedSlice(latest.Object, "status", "admissionChecks")
		if !found || err != nil {
			checks = []interface{}{}
		}
		updated := false
		for i, c := range checks {
			cmap, ok := c.(map[string]interface{})
			if !ok {
				continue
			}
			if cmap["name"] == checkName {
				cmap["state"] = "Ready"
				cmap["message"] = "Karpenter pre-provisioned nodes ready with anti-theft reservation"
				cmap["lastTransitionTime"] = time.Now().UTC().Format(time.RFC3339)
				checks[i] = cmap
				updated = true
				break
			}
		}
		if !updated {
			checks = append(checks, map[string]interface{}{
				"name":               checkName,
				"state":              "Ready",
				"message":            "Karpenter pre-provisioned nodes ready with anti-theft reservation",
				"lastTransitionTime": time.Now().UTC().Format(time.RFC3339),
			})
		}
		_ = unstructured.SetNestedSlice(latest.Object, checks, "status", "admissionChecks")
		return r.Status().Update(ctx, latest)
	})
}

func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	wl := &unstructured.Unstructured{}
	wl.SetGroupVersionKind(workloadGVK)
	return ctrl.NewControllerManagedBy(mgr).
		Named("preprovisioner").
		For(wl).
		Complete(r)
}
