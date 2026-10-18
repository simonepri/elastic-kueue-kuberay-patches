package nodesim

import (
	"context"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

type Reconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	node := &corev1.Node{}
	if err := r.Get(ctx, req.NamespacedName, node); err != nil {
		if errors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	if len(node.Name) < 10 || node.Name[:10] != "simulated-" {
		return ctrl.Result{}, nil
	}

	for _, c := range node.Status.Conditions {
		if c.Type == corev1.NodeReady && c.Status == corev1.ConditionTrue {
			return ctrl.Result{}, nil
		}
	}

	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		latest := &corev1.Node{}
		if err := r.Get(ctx, req.NamespacedName, latest); err != nil {
			return err
		}
		now := metav1.Now()
		latest.Status.Conditions = []corev1.NodeCondition{
			{
				Type:               corev1.NodeReady,
				Status:             corev1.ConditionTrue,
				LastHeartbeatTime:  now,
				LastTransitionTime: now,
				Reason:             "KubeletReady",
				Message:            "Simulated node ready",
			},
		}
		latest.Status.Allocatable = corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("32"),
			corev1.ResourceMemory: resource.MustParse("128Gi"),
			corev1.ResourcePods:   resource.MustParse("110"),
		}
		latest.Status.Capacity = corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("32"),
			corev1.ResourceMemory: resource.MustParse("128Gi"),
			corev1.ResourcePods:   resource.MustParse("110"),
		}
		return r.Status().Update(ctx, latest)
	})
	if err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	return ctrl.Result{}, nil
}

func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		Named("nodesim").
		For(&corev1.Node{}).
		Complete(r)
}
