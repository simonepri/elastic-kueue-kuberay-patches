package actorprotect

import (
	"context"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

const (
	PodDeletionCostAnnotation = "controller.kubernetes.io/pod-deletion-cost"
	ActorStateLabel           = "ray.io/actor-state"
)

type Reconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	pod := &corev1.Pod{}
	if err := r.Get(ctx, req.NamespacedName, pod); err != nil {
		if errors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	state := pod.GetLabels()[ActorStateLabel]
	if state == "" {
		return ctrl.Result{}, nil
	}

	expectedCost := ""
	switch state {
	case "busy":
		expectedCost = "1000"
	case "idle":
		expectedCost = "-1000"
	default:
		return ctrl.Result{}, nil
	}

	currentCost := ""
	if pod.GetAnnotations() != nil {
		currentCost = pod.GetAnnotations()[PodDeletionCostAnnotation]
	}

	if currentCost != expectedCost {
		logger.Info("updating pod deletion cost based on actor state",
			"pod", pod.GetName(), "state", state, "cost", expectedCost)
		err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
			latest := &corev1.Pod{}
			if err := r.Get(ctx, req.NamespacedName, latest); err != nil {
				return err
			}
			ann := latest.GetAnnotations()
			if ann == nil {
				ann = make(map[string]string)
			}
			ann[PodDeletionCostAnnotation] = expectedCost
			latest.SetAnnotations(ann)
			return r.Update(ctx, latest)
		})
		if err != nil {
			return ctrl.Result{}, err
		}
	}

	return ctrl.Result{}, nil
}

func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		Named("actorprotect").
		For(&corev1.Pod{}).
		Complete(r)
}
