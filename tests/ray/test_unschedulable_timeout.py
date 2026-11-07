"""Check that the autoscaler gives up on unplaceable KubeRay worker pods sooner than on placed ones that are starting.

Runs inside a Ray image with `python -m unittest`; it fails on the stock image and
passes once patches/ray is applied.
"""

import time
import unittest
from unittest import mock

from ray.autoscaler._private.kuberay.node_provider import (
    KUBERAY_KIND_WORKER,
    KUBERAY_LABEL_KEY_KIND,
    KUBERAY_LABEL_KEY_TYPE,
)
from ray.autoscaler.v2.instance_manager.cloud_providers.kuberay.cloud_provider import (
    KubeRayProvider,
)
from ray.autoscaler.v2.instance_manager.config import (
    InstanceReconcileConfig,
    Provider,
)
from ray.autoscaler.v2.instance_manager.instance_manager import InstanceManager
from ray.autoscaler.v2.instance_manager.instance_storage import InstanceStorage
from ray.autoscaler.v2.instance_manager.reconciler import Reconciler
from ray.autoscaler.v2.instance_manager.storage import InMemoryStorage
from ray.autoscaler.v2.instance_manager.subscribers.cloud_resource_monitor import (
    CloudResourceMonitor,
)
from ray.autoscaler.v2.scheduler import IResourceScheduler, SchedulingReply
from ray.core.generated.autoscaler_pb2 import ClusterResourceState
from ray.core.generated.instance_manager_pb2 import Instance, NodeKind

s_to_ns = 1_000_000_000
ALLOCATE_TIMEOUT_S = 900
UNSCHEDULABLE_TIMEOUT_S = 120
PROVISIONING_TIMEOUT_S = 600


def worker_pod(name, spec=None, status=None):
    return {
        "metadata": {
            "name": name,
            "labels": {
                KUBERAY_LABEL_KEY_KIND: KUBERAY_KIND_WORKER,
                KUBERAY_LABEL_KEY_TYPE: "gpu-group",
            },
        },
        "spec": spec or {},
        "status": status or {"phase": "Pending"},
    }


GATED_POD = worker_pod(
    "gated",
    spec={"schedulingGates": [{"name": "kueue.x-k8s.io/admission"}]},
)
UNSCHEDULABLE_POD = worker_pod(
    "unschedulable",
    spec={"nodeSelector": {"gpu-class": "t4", "capacity-provider": "cell"}},
    status={
        "phase": "Pending",
        "conditions": [
            {"type": "PodScheduled", "status": "False", "reason": "Unschedulable"}
        ],
    },
)


def node_claim(initialized=False, deleting=False, gpu_class="t4", provider="cell"):
    """A Karpenter NodeClaim whose requirements name a GPU class and a provider."""
    claim = {
        "metadata": {"name": "claim", "labels": {"capacity-provider": provider}},
        "spec": {
            "requirements": [
                {"key": "gpu-class", "operator": "In", "values": [gpu_class]},
                {"key": "karpenter.sh/capacity-type", "operator": "In", "values": ["spot"]},
            ]
        },
        "status": {
            "conditions": [
                {"type": "Launched", "status": "True"},
                {"type": "Initialized", "status": "True" if initialized else "False"},
            ]
        },
    }
    if deleting:
        claim["metadata"]["deletionTimestamp"] = "2026-01-01T00:00:00Z"
    return claim


PULLING_POD = worker_pod(
    "pulling",
    spec={"nodeName": "node-1"},
    status={
        "phase": "Pending",
        "conditions": [{"type": "PodScheduled", "status": "True"}],
        "containerStatuses": [
            {"state": {"waiting": {"reason": "ContainerCreating"}}}
        ],
    },
)


class MockScheduler(IResourceScheduler):
    def schedule(self, req):
        return SchedulingReply()


class MockAutoscalingConfig:
    def __init__(self, reconcile_config, pending_idle_timeout_s=None):
        self._reconcile_config = reconcile_config
        self._pending_idle_timeout_s = pending_idle_timeout_s

    def get_node_type_configs(self):
        return {}

    def get_max_num_worker_nodes(self):
        return None

    def get_max_num_nodes(self):
        return None

    def get_upscaling_speed(self):
        return 0.0

    def get_max_concurrent_launches(self):
        return 0

    def get_instance_reconcile_config(self):
        return self._reconcile_config

    def disable_node_updaters(self):
        return True

    def disable_launch_config_check(self):
        return True

    def get_idle_timeout_s(self):
        return 999

    def get_pending_idle_timeout_s(self):
        return self._pending_idle_timeout_s

    def get_provider_instance_type(self, ray_node_type):
        return ""

    @property
    def provider(self):
        return Provider.KUBERAY


class UnschedulableTimeoutTest(unittest.TestCase):
    def reconcile(
        self, pod, allocated_for_s, pending_idle_timeout_s=None, node_claims=None
    ):
        """Reconcile one ALLOCATED instance backed by pod and return its status history."""
        storage = InstanceStorage(cluster_id="test", storage=InMemoryStorage())
        instance_manager = InstanceManager(
            instance_storage=storage, instance_status_update_subscribers=[]
        )
        now_s = 10_000
        instance = Instance(
            instance_id="i-1",
            status=Instance.ALLOCATED,
            instance_type="gpu-group",
            node_kind=NodeKind.WORKER,
            cloud_instance_id=pod["metadata"]["name"],
            status_history=[
                Instance.StatusHistory(
                    instance_status=Instance.ALLOCATED,
                    timestamp_ns=(now_s - allocated_for_s) * s_to_ns,
                )
            ],
        )
        ok, _ = storage.upsert_instance(instance)
        self.assertTrue(ok)
        cloud_instance = KubeRayProvider._cloud_instance_from_pod(pod, node_claims)
        with mock.patch.object(time, "time_ns", return_value=now_s * s_to_ns):
            Reconciler.reconcile(
                instance_manager=instance_manager,
                scheduler=MockScheduler(),
                cloud_provider=mock.MagicMock(),
                cloud_resource_monitor=CloudResourceMonitor(),
                ray_cluster_resource_state=ClusterResourceState(),
                non_terminated_cloud_instances={
                    cloud_instance.cloud_instance_id: cloud_instance
                },
                cloud_provider_errors=[],
                ray_install_errors=[],
                autoscaling_config=MockAutoscalingConfig(
                    InstanceReconcileConfig(
                        allocate_status_timeout_s=ALLOCATE_TIMEOUT_S,
                        unschedulable_status_timeout_s=UNSCHEDULABLE_TIMEOUT_S,
                        provisioning_status_timeout_s=PROVISIONING_TIMEOUT_S,
                    ),
                    pending_idle_timeout_s=pending_idle_timeout_s,
                ),
            )
        instances, _ = storage.get_instances()
        return [h.instance_status for h in instances["i-1"].status_history]

    def test_default_unschedulable_timeout_is_two_minutes(self):
        self.assertEqual(InstanceReconcileConfig().unschedulable_status_timeout_s, 120)

    def test_default_provisioning_timeout_is_ten_minutes(self):
        self.assertEqual(InstanceReconcileConfig().provisioning_status_timeout_s, 600)

    def test_only_a_rejected_pod_can_have_a_host_provisioning(self):
        claims = [node_claim()]
        host = KubeRayProvider._is_host_provisioning
        self.assertTrue(host(UNSCHEDULABLE_POD, claims))
        self.assertFalse(host(GATED_POD, claims))
        self.assertFalse(host(PULLING_POD, claims))

    def test_node_claim_must_be_uninitialized_alive_and_match_the_selector(self):
        host = KubeRayProvider._is_host_provisioning
        self.assertFalse(host(UNSCHEDULABLE_POD, None))
        self.assertFalse(host(UNSCHEDULABLE_POD, []))
        self.assertFalse(host(UNSCHEDULABLE_POD, [node_claim(initialized=True)]))
        self.assertFalse(host(UNSCHEDULABLE_POD, [node_claim(deleting=True)]))
        self.assertFalse(host(UNSCHEDULABLE_POD, [node_claim(gpu_class="l4")]))
        self.assertFalse(host(UNSCHEDULABLE_POD, [node_claim(provider="cloudvm")]))
        self.assertTrue(
            host(UNSCHEDULABLE_POD, [node_claim(gpu_class="l4"), node_claim()])
        )

    def test_pod_without_a_node_selector_never_has_a_host_provisioning(self):
        pod = worker_pod(
            "plain",
            status=UNSCHEDULABLE_POD["status"],
        )
        self.assertFalse(KubeRayProvider._is_host_provisioning(pod, [node_claim()]))

    def test_failed_node_claim_lookup_means_no_host_provisioning(self):
        provider = KubeRayProvider.__new__(KubeRayProvider)
        provider._get = mock.MagicMock(side_effect=RuntimeError("forbidden"))
        self.assertEqual(provider._list_node_claims([UNSCHEDULABLE_POD]), [])
        provider._get.assert_called_once_with("nodeclaims")

    def test_node_claims_are_only_listed_for_a_rejected_pod(self):
        provider = KubeRayProvider.__new__(KubeRayProvider)
        provider._get = mock.MagicMock(return_value={"items": [node_claim()]})
        self.assertEqual(provider._list_node_claims([GATED_POD, PULLING_POD]), [])
        provider._get.assert_not_called()
        self.assertEqual(len(provider._list_node_claims([UNSCHEDULABLE_POD])), 1)

    def test_pods_without_a_node_are_unschedulable_when_gated_or_rejected(self):
        self.assertTrue(KubeRayProvider._is_unschedulable(GATED_POD))
        self.assertTrue(KubeRayProvider._is_unschedulable(UNSCHEDULABLE_POD))
        self.assertFalse(KubeRayProvider._is_unschedulable(PULLING_POD))
        self.assertFalse(KubeRayProvider._is_unschedulable(worker_pod("new")))

    def test_gated_pod_times_out_at_the_unschedulable_timeout(self):
        before = self.reconcile(GATED_POD, UNSCHEDULABLE_TIMEOUT_S - 1)
        self.assertNotIn(Instance.ALLOCATION_TIMEOUT, before)
        after = self.reconcile(GATED_POD, UNSCHEDULABLE_TIMEOUT_S + 1)
        self.assertIn(Instance.ALLOCATION_TIMEOUT, after)

    def test_rejected_pod_with_a_host_coming_waits_for_it(self):
        # The scheduler rejects the pod while its new node boots and its GPU device
        # plugin registers; that takes longer than the unschedulable timeout.
        history = self.reconcile(
            UNSCHEDULABLE_POD, PROVISIONING_TIMEOUT_S - 1, node_claims=[node_claim()]
        )
        self.assertEqual(history, [Instance.ALLOCATED])

    def test_rejected_pod_with_a_host_coming_times_out_at_the_provisioning_timeout(
        self,
    ):
        history = self.reconcile(
            UNSCHEDULABLE_POD, PROVISIONING_TIMEOUT_S + 1, node_claims=[node_claim()]
        )
        self.assertIn(Instance.ALLOCATION_TIMEOUT, history)

    def test_rejected_pod_with_no_host_coming_times_out_at_the_unschedulable_timeout(
        self,
    ):
        for claims in (None, [], [node_claim(gpu_class="l4")]):
            history = self.reconcile(
                UNSCHEDULABLE_POD, UNSCHEDULABLE_TIMEOUT_S + 1, node_claims=claims
            )
            self.assertIn(Instance.ALLOCATION_TIMEOUT, history)

    def test_gated_pod_ignores_a_matching_node_claim(self):
        history = self.reconcile(
            GATED_POD, UNSCHEDULABLE_TIMEOUT_S + 1, node_claims=[node_claim()]
        )
        self.assertIn(Instance.ALLOCATION_TIMEOUT, history)

    def test_scheduled_pod_pulling_its_image_outlives_the_unschedulable_timeout(self):
        history = self.reconcile(PULLING_POD, ALLOCATE_TIMEOUT_S - 1)
        self.assertEqual(history, [Instance.ALLOCATED])

    def test_scheduled_pod_still_times_out_at_the_allocate_timeout(self):
        history = self.reconcile(PULLING_POD, ALLOCATE_TIMEOUT_S + 1)
        self.assertIn(Instance.ALLOCATION_TIMEOUT, history)

    def test_unschedulable_pod_times_out_with_pending_idle_timeout_configured(self):
        history = self.reconcile(
            UNSCHEDULABLE_POD,
            UNSCHEDULABLE_TIMEOUT_S + 1,
            pending_idle_timeout_s=600.0,
        )
        self.assertIn(Instance.ALLOCATION_TIMEOUT, history)


if __name__ == "__main__":
    unittest.main()
