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
    status={
        "phase": "Pending",
        "conditions": [
            {"type": "PodScheduled", "status": "False", "reason": "Unschedulable"}
        ],
    },
)
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
    def __init__(self, reconcile_config):
        self._reconcile_config = reconcile_config

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

    def get_provider_instance_type(self, ray_node_type):
        return ""

    @property
    def provider(self):
        return Provider.KUBERAY


class UnschedulableTimeoutTest(unittest.TestCase):
    def reconcile(self, pod, allocated_for_s):
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
        cloud_instance = KubeRayProvider._cloud_instance_from_pod(pod)
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
                    )
                ),
            )
        instances, _ = storage.get_instances()
        return [h.instance_status for h in instances["i-1"].status_history]

    def test_default_unschedulable_timeout_is_two_minutes(self):
        self.assertEqual(InstanceReconcileConfig().unschedulable_status_timeout_s, 120)

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

    def test_unschedulable_pod_times_out_at_the_unschedulable_timeout(self):
        history = self.reconcile(UNSCHEDULABLE_POD, UNSCHEDULABLE_TIMEOUT_S + 1)
        self.assertIn(Instance.ALLOCATION_TIMEOUT, history)

    def test_scheduled_pod_pulling_its_image_outlives_the_unschedulable_timeout(self):
        history = self.reconcile(PULLING_POD, ALLOCATE_TIMEOUT_S - 1)
        self.assertEqual(history, [Instance.ALLOCATED])

    def test_scheduled_pod_still_times_out_at_the_allocate_timeout(self):
        history = self.reconcile(PULLING_POD, ALLOCATE_TIMEOUT_S + 1)
        self.assertIn(Instance.ALLOCATION_TIMEOUT, history)


if __name__ == "__main__":
    unittest.main()
