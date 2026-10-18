package spotinterruption

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

const (
	AnnotationProcessed = "kyield.io/spot-interruption-processed"
)

var (
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

	cm := &corev1.ConfigMap{}
	if err := r.Get(ctx, req.NamespacedName, cm); err != nil {
		if errors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	if cm.Labels["test.k8s.io/event"] != "spot-interrupted" && cm.Labels["kyield.io/event"] != "spot-interrupted" {
		return ctrl.Result{}, nil
	}

	if cm.Annotations != nil && cm.Annotations[AnnotationProcessed] == "true" {
		return ctrl.Result{}, nil
	}

	targetCluster := cm.Labels["target-cluster"]
	if targetCluster == "" {
		return ctrl.Result{}, nil
	}

	groupName := cm.Data["workerGroup"]
	targetPod := cm.Data["interruptedPod"]
	var interrupted int64 = 1
	if val, ok := cm.Data["interruptedReplicas"]; ok {
		fmt.Sscanf(val, "%d", &interrupted)
	}

	logger.Info("handling spot interruption for cluster",
		"cluster", targetCluster, "group", groupName, "interrupted", interrupted, "targetPod", targetPod)

	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		latest := &unstructured.Unstructured{}
		latest.SetGroupVersionKind(rayClusterGVK)
		if err := r.Get(ctx, client.ObjectKey{Namespace: cm.Namespace, Name: targetCluster}, latest); err != nil {
			return err
		}
		wgs, found, _ := unstructured.NestedSlice(latest.Object, "spec", "workerGroupSpecs")
		if !found || len(wgs) == 0 {
			return nil
		}
		modified := false
		for i, wg := range wgs {
			wgMap, ok := wg.(map[string]interface{})
			if !ok {
				continue
			}
			if wgMap["groupName"] == groupName || groupName == "" {
				curReplicas, _ := wgMap["replicas"].(int64)
				if curReplicas > interrupted {
					newReplicas := curReplicas - interrupted
					logger.Info("contracting workerGroup replicas and maxReplicas to match surviving capacity",
						"cluster", targetCluster, "old", curReplicas, "new", newReplicas)
					wgMap["replicas"] = newReplicas
					wgMap["maxReplicas"] = newReplicas

					if targetPod != "" {
						strategy, _, _ := unstructured.NestedMap(wgMap, "scaleStrategy")
						if strategy == nil {
							strategy = map[string]interface{}{}
						}
						toDelete, _, _ := unstructured.NestedStringSlice(strategy, "workersToDelete")
						toDelete = append(toDelete, targetPod)
						strategy["workersToDelete"] = toDelete
						wgMap["scaleStrategy"] = strategy
					}

					wgs[i] = wgMap
					modified = true
				}
			}
		}
		if modified {
			_ = unstructured.SetNestedSlice(latest.Object, wgs, "spec", "workerGroupSpecs")
			return r.Update(ctx, latest)
		}
		return nil
	})

	if err != nil {
		return ctrl.Result{}, err
	}

	// Mark processed for idempotency
	_ = retry.RetryOnConflict(retry.DefaultRetry, func() error {
		latestCm := &corev1.ConfigMap{}
		if err := r.Get(ctx, req.NamespacedName, latestCm); err != nil {
			return err
		}
		ann := latestCm.GetAnnotations()
		if ann == nil {
			ann = map[string]string{}
		}
		ann[AnnotationProcessed] = "true"
		latestCm.SetAnnotations(ann)
		return r.Update(ctx, latestCm)
	})

	return ctrl.Result{}, nil
}

func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		Named("spotinterruption").
		For(&corev1.ConfigMap{}).
		Complete(r)
}
