# Elastic Kueue & KubeRay Patches

[![CI](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/ci.yaml/badge.svg)](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/ci.yaml)
[![Release Please](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/release-please.yaml/badge.svg)](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/release-please.yaml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Tested on Kueue](https://img.shields.io/badge/tested%20on%20kueue-v0.20.2-blue)](https://github.com/kubernetes-sigs/kueue/releases/tag/v0.20.2)
[![Tested on KubeRay](https://img.shields.io/badge/tested%20on%20kuberay-v1.7.1-blue)](https://github.com/ray-project/kuberay/releases/tag/v1.7.1)
[![Tested on Karpenter](https://img.shields.io/badge/tested%20on%20karpenter-v1.15.0-blue)](https://github.com/kubernetes-sigs/karpenter/releases/tag/v1.15.0)
[![Tested on interLink](https://img.shields.io/badge/tested%20on%20interlink-0.6.2-blue)](https://github.com/interlink-hq/interLink/releases/tag/0.6.2)
[![Tested on Ray](https://img.shields.io/badge/tested%20on%20ray-2.59.0-blue)](https://github.com/ray-project/ray/releases/tag/ray-2.59.0)

Production patchsets for running elastic Ray clusters shared across teams on Kubernetes with [Kueue](https://github.com/kubernetes-sigs/kueue), [KubeRay](https://github.com/ray-project/kuberay), and [Karpenter](https://github.com/kubernetes-sigs/karpenter), plus a patched [interLink](https://github.com/interlink-hq/interLink) virtual kubelet for bursting Ray workers onto remote capacity and a patched [Ray](https://github.com/ray-project/ray) image whose head reaches those workers' agents through the gRPC proxy and whose autoscaler gives up sooner on worker pods that cannot be placed.

---

## Architecture Overview

### Stock Upstream Architecture

In stock upstream Kubernetes, Kueue, KubeRay, and Karpenter operate as isolated control loops without elastic coordination:

```
+-----------------------------------------------------------------------------------+
|                            STOCK UPSTREAM ARCHITECTURE                            |
+-----------------------------------------------------------------------------------+

   +-------------+       +-------------------+       +--------------------------+
   |    Kueue    |       |  KubeRay Operator |       |        Karpenter         |
   +-------------+       +-------------------+       +--------------------------+
          |                        |                               |
          | (1) Preempts ALL       | (2) Drains worker             | (3) Blindly provisions
          |     workers if quota   |     pods arbitrarily;         |     new nodes on demand;
          |     is exceeded        |     kills active actors       |     no gang reservations
          v                        v                               v
   +----------------------------------------------------------------------------+
   |                              Kubernetes Nodes                              |
   |                                                                            |
   |  [X] Ray Cluster (Evicted)      [X] Busy Actors Lost    [!] Stolen Nodes   |
   +----------------------------------------------------------------------------+
```

### Patched Collaborative Architecture

With these patches applied, Kueue and KubeRay communicate dynamically through Kubernetes native primitives:

```
+-----------------------------------------------------------------------------------+
|                        PATCHED COLLABORATIVE ARCHITECTURE                         |
+-----------------------------------------------------------------------------------+

   +--------------------------+                  +--------------------------+
   |       Patched Kueue      |                  |     Patched KubeRay      |
   +--------------------------+                  +--------------------------+
          |            ^                                |            ^
          |            |                                |            |
          | (1) Elastic Ray Clusters:                   | (2) Actor Protection:
          |     Resizes workers through                 |     Annotates pods with
          |     workload slices; partial                |     pod-deletion-cost
          |     preemption is being rebuilt             |     to protect busy actors
          |                                             |
          | (3) Karpenter JIT Gang Check:               | (4) ScaleGate Controller:
          |     Mints NodeClaims with                   |     Clamps maxReplicas
          |     anti-theft taints                       |     to Kueue borrowing cap
          v                                             v
   +----------------------------------------------------------------------------+
   |                              Kubernetes Nodes                              |
   |                                                                            |
   |  [*] Head Pod Survives          [*] Actors Protected    [*] Tainted Gangs  |
   +----------------------------------------------------------------------------+
```

---

## Upstream Issues, Patches & Test Scenarios

The table below outlines the core architectural issues in upstream controllers and tracks the implementation of fixes and validating test suites:

| # | Target Upstream | Patch File | Architectural Defect / Gap | Controller Fix | Validating Test Scenarios |
| :-: | :--- | :--- | :--- | :--- | :--- |
| **17** | `kubernetes-sigs/kueue` | [`0001-workload-scale-down-below-min-count.patch`](patches/kueue/0001-workload-scale-down-below-min-count.patch) | An elastic RayCluster with the `kueue.x-k8s.io/elastic-job-scale-up-strategy: partial` annotation gets a Workload whose worker `minCount` is the worker count it was created with. When the cluster scales below that count, Kueue lowers the Workload's `count` in place but keeps `minCount`, so the API server rejects the update with `minCount should be less or equal to count` and the scale-down never reaches the Workload or releases quota. Upstream: [PR #16742](https://github.com/kubernetes-sigs/kueue/pull/16742) (open). | Backports PR #16742 as of commit `b28eeae`: a scale-down caps each `minCount` at the new count, the Workload webhook accepts a `minCount` lowered to exactly the new count during a scale-down, and a Workload that has never held quota takes `minCount` from the job again, so its first admission stays all-or-nothing. The PR's KEP text and end-to-end test are left out. | `TestValidateWorkloadUpdateScaleDownMinCount` in `pkg/webhooks/workload_webhook_test.go`, `TestApplyPodSetCounts` in `pkg/workload/podsetscounts_test.go`, `TestEnsureWorkloadSlicesScaleDownMinCount` and `TestEnsureWorkloadSlicesPendingMinCount` in `pkg/workloadslicing/workloadslicing_test.go`, and "Should release quota when a partial scale-up RayCluster shrinks below its minimum" in `test/integration/singlecluster/controller/jobs/raycluster/raycluster_controller_partial_scaleup_test.go` (added by the patch; `mise run test:kueue` and `mise run test:kueue-integration`) |
| **18** | `kubernetes-sigs/kueue` | [`0002-ray-min-count-migration.patch`](patches/kueue/0002-ray-min-count-migration.patch) | Patch releases up to p0.6.x set `minCount` to `minReplicas` on every worker group of a RayCluster, RayJob, or RayService Workload, and KubeRay defaults `minReplicas` to 0. Kueue compares `minCount` when it checks that a job still matches its Workload, so after an upgrade every running Ray job those releases admitted stops matching: Kueue deletes its Workload and suspends the job. Temporary, for the upgrade only. | The Ray integrations ignore `minCount` in that check while the Workload holds quota, through their `CustomEquivalenceOptions` and a new `WithIgnoreMinCount` comparison option. Those releases also shrank multi-host worker groups to pod counts that are not whole replicas and set `replicas` rounded down, so while the Workload holds quota a job also matches when its pod count is the admitted count rounded down to whole replicas (`WithCountsInWholeSteps`). `minCount` only decides how many pods a Workload may be admitted with, so it cannot change what a Workload holding quota runs; once the quota is released, Kueue replaces the Workload's PodSets with the job's as usual, which drops the old `minCount`. Delete the patch once no Workload that held quota under p0.6.x or earlier remains ([migration](patches/kueue/contract.md#migration-from-p06x)). | `TestMinCountMigrationEquivalence`, `TestMinCountMigrationKeepsRunningCluster`, and `TestMinCountMigrationMultiHostShrink` in `pkg/controller/jobs/raycluster/min_count_migration_test.go`, and `TestMinCountMigrationSliceChain` in `pkg/controller/jobframework/min_count_migration_test.go` (added by the patch; `mise run test:kueue`) |
| **3** | `kubernetes-sigs/kueue` | [`0003-karpenter-jit-reservation.patch`](patches/kueue/0003-karpenter-jit-reservation.patch) | Kueue relies on standard cluster autoscalers reactively; cold-start gang workloads stall without JIT capacity, newly provisioned nodes get stolen by rogue unmanaged pods, and a workload whose flavor has no capacity waits on it forever instead of moving to the next flavor. | Implements an in-tree Karpenter AdmissionCheck controller that creates `NodeClaim`s in the NodePool the flavor names, each requesting the resources of the admitted pods packed onto it, restricted to the flavor's node labels and tainted `karpenter.sh/claimed-by=<workload>`, and keeps the check Pending until every NodeClaim is `Launched` (or `Registered`). When a NodeClaim is deleted first, as Karpenter does on insufficient capacity, or the launch timeout passes, it deletes the NodeClaims, excludes the flavor through the `kueue.x-k8s.io/workload-allowed-resource-flavors` annotation, and sets the check to Retry, so Kueue assigns the next flavor. Kueue honors that annotation only with the `ConcurrentAdmission` feature gate, which the check requires. | [`tests/scenarios/kueue/03-karpenter-jit-reservation/01-cold-start-gang`](tests/scenarios/kueue/03-karpenter-jit-reservation/01-cold-start-gang)<br>[`tests/scenarios/kueue/03-karpenter-jit-reservation/02-anti-theft-taint`](tests/scenarios/kueue/03-karpenter-jit-reservation/02-anti-theft-taint)<br>[`tests/scenarios/kueue/03-karpenter-jit-reservation/03-launch-timeout-fallback`](tests/scenarios/kueue/03-karpenter-jit-reservation/03-launch-timeout-fallback)<br>`pkg/controller/admissionchecks/karpenter/controller_test.go` (added by the patch; `mise run test:kueue` and `mise run test:kueue-integration`) |
| **14** | `kubernetes-sigs/kueue` | [`0004-deployment-queue-mutation.patch`](patches/kueue/0004-deployment-queue-mutation.patch) | Once any Deployment Pod is ready, the Deployment's `kueue.x-k8s.io/queue-name` label is immutable and a `kueue.x-k8s.io/priority-class` label can no longer be added, as if the Deployment were a single gang-admitted job. Kueue admits each Deployment Pod as its own workload, so moving a serving Deployment to another queue or giving it a WorkloadPriorityClass requires deleting and recreating it. | A running Deployment may change its queue name and add a WorkloadPriorityClass when it had none. The webhook copies both labels onto the Pod template on every update, so the rolled Pods get workloads in the new queue with the new class, while existing Pods and workloads are untouched. Removing either label stays rejected; other kinds keep upstream validation, and the namespace default class is still not applied to a running Deployment, since that would roll every Pod on an unrelated update. | `TestValidateUpdate` and `TestDefault` in `pkg/controller/jobs/deployment/deployment_webhook_test.go` (extended by the patch; `mise run test:kueue`) |
| **4** | `ray-project/kuberay` | [`0001-actor-protect.patch`](patches/kuberay/0001-actor-protect.patch) | The Ray autoscaler terminates worker pods without Kubernetes awareness, killing pods actively executing stateful actor workloads during scale-down. | Operator inspects worker `ray.io/actor-state` labels and manages `controller.kubernetes.io/pod-deletion-cost` (e.g. `+1000` for busy actors, `-1000` for idle workers). | [`tests/scenarios/kuberay/01-actor-protect/01-actor-aware-drain`](tests/scenarios/kuberay/01-actor-protect/01-actor-aware-drain) |
| **5** | `ray-project/kuberay` | [`0002-spot-interruption.patch`](patches/kuberay/0002-spot-interruption.patch) | Cloud spot interruptions (AWS 2-minute notice / GCP 30-second notice) trigger abrupt node termination and worker pod eviction without coordinated state drain. | Operator intercepts spot interruption notices, flags affected Ray pods, and coordinates graceful actor migration before the physical node is terminated. | [`tests/scenarios/kuberay/02-spot-interruption/01-spot-termination-drain`](tests/scenarios/kuberay/02-spot-interruption/01-spot-termination-drain) |
| **6** | `ray-project/kuberay` | [`0003-scalegate.patch`](patches/kuberay/0003-scalegate.patch) | Ray autoscaler requests scale-up beyond ClusterQueue quota and cohort limits, leading to stuck pending pods and quota starvation for other tenants. | ScaleGate reconciler clamps each worker group's `maxReplicas` to the most workers the ClusterQueue could ever hold, and writes nothing else: the Ray autoscaler is the only writer of `replicas` and `workersToDelete`, and the operator creates at most `maxReplicas` workers whatever `replicas` says. Within a resource group a worker may land on any flavor, so the group fits as many workers as its largest flavor; the worker must fit every resource group it uses, so the smallest group sets the bound. A flavor offers its nominal quota without a cohort; with a cohort, a missing `borrowingLimit` means unlimited borrowing, so the flavor offers the sum of nominal quotas of every ClusterQueue and Cohort in the cohort tree, lowered to nominal quota plus `borrowingLimit` when one is set. That sum ignores lending limits, usage, and flavor node labels, so the bound can be loose but never cuts below what Kueue can admit. The clamp never goes below the pod count Kueue admitted for the group, which is the authority on what fits, nor below `minReplicas`, so the operator never sees `minReplicas` greater than `maxReplicas`. ScaleGate only lowers `maxReplicas`: after the quota grows, the field keeps its lower value until its owner raises it, because raising it back would need ScaleGate to remember the declared value and write the field against that owner. A GitOps tool that reverts drift must ignore `spec.workerGroupSpecs[].maxReplicas` on Kueue-queued RayClusters, or it undoes the clamp and the two rewrite the field in turn. | [`tests/scenarios/kuberay/03-scalegate-quota/01-scaleup-clamping`](tests/scenarios/kuberay/03-scalegate-quota/01-scaleup-clamping)<br>[`tests/scenarios/kuberay/03-scalegate-quota/02-admitted-borrow-only-flavor`](tests/scenarios/kuberay/03-scalegate-quota/02-admitted-borrow-only-flavor)<br>[`tests/scenarios/kuberay/03-scalegate-quota/03-borrowing-limit-clamping`](tests/scenarios/kuberay/03-scalegate-quota/03-borrowing-limit-clamping)<br>[`tests/scenarios/kuberay/03-scalegate-quota/04-min-replicas-floor`](tests/scenarios/kuberay/03-scalegate-quota/04-min-replicas-floor)<br>`controllers/ray/scalegate_controller_unit_test.go` (added by the patch; `mise run test:kuberay`) |
| **15** | `ray-project/kuberay` | [`0004-parallel-worker-creation.patch`](patches/kuberay/0004-parallel-worker-creation.patch) | `reconcilePods` creates a worker group's missing Pods one at a time and waits for each create, including every admission webhook it passes, before sending the next, so a large group takes minutes to create its Pods: at 0.75 s per create, 200 workers take 150 s. | Creates the missing Pods concurrently in batches of 1, 2, 4, ... like the ReplicaSet and Job controllers, with and without `RayMultiHostIndexing`, which picks every replica index before the first create. After the first batch with a failed create the reconcile stops and returns the errors, so an API server that rejects every Pod sees only a few failed creates; the Pods already created stay, and the next reconcile creates only the rest. Each Pod gets its own copy of the operator's worker sidecar containers, so Pods built at the same time share no slices. Multi-host replica groups and `workersToDelete` deletions stay sequential. | `TestSlowStartBatch*` in `controllers/ray/slow_start_batch_unit_test.go` (added by the patch; `mise run test:kuberay`, with the race detector) |
| **7** | `interlink-hq/interLink` | [`0001-terminated-reason-nil-guard.patch`](patches/interlink/0001-terminated-reason-nil-guard.patch) | When a pod fails, `checkPodsStatus` rewrites `State.Terminated.Reason` on every container status; a status the plugin did not report is not terminated, so the virtual kubelet panics on a nil dereference and crash-loops the node. Upstream: [issue drafted, not filed](#interlink-upstream-issue-draft). | Rewrites the failure reason only on container statuses that are terminated. | `TestCheckPodsStatusFailedPodWithNonTerminatedContainer` in `pkg/virtualkubelet/execute_terminated_reason_test.go` (added by the patch; `mise run test:interlink`) |
| **8** | `interlink-hq/interLink` | [`0002-container-status-index.patch`](patches/interlink/0002-container-status-index.patch) | When a remote container name matches no in-cluster status, `handleContainersUpdate` and `handleInitContainersUpdate` append it but keep updating index 0, marking the wrong container Ready or panicking on its nil `Terminated` state. Upstream: [issue drafted, not filed](#interlink-upstream-issue-draft). | Updates the entry the remote status names: a pod spec container without a status is appended and updated at its own index; a name outside the pod spec still counts toward the pod phase but is never written to the pod status. | `TestHandleContainersUpdateUnknownContainer` and `TestHandleInitContainersUpdateUnknownContainer` in `pkg/virtualkubelet/execute_container_status_test.go` (added by the patch; `mise run test:interlink`) |
| **9** | `interlink-hq/interLink` | [`0003-image-pull-secrets.patch`](patches/interlink/0003-image-pull-secrets.patch) | The create request carries only the Secrets that volumes mount, not those named in `spec.imagePullSecrets`, so a plugin pulling images on remote capacity must read Secrets from the Kubernetes API itself, with its own RBAC. Upstream: not yet reported. | Adds each referenced `dockerconfigjson` or `dockercfg` Secret to the request's `secrets`, once per name; like the kubelet, warns and continues when a pull secret is missing, unreadable, or of another type. | `TestRemoteExecutionHandleImagePullSecrets` in `pkg/virtualkubelet/execute_image_pull_secrets_test.go` (added by the patch; `mise run test:interlink`) |
| **10** | `interlink-hq/interLink` | [`0004-env-fieldref-paths.patch`](patches/interlink/0004-env-fieldref-paths.patch) | Env `fieldRef`s resolve only `status.podIP`, `metadata.name`, `metadata.namespace`, `metadata.uid`, and single annotations; every other path, such as `metadata.labels['topology.kubernetes.io/region']` or `spec.nodeName`, silently becomes an empty string. Upstream: not yet reported. | Resolves env `fieldRef`s with the downward API volume resolver, extended to single label and annotation references; a missing key resolves to the empty string as in the kubelet, and an unsupported path is logged and left unresolved. | `TestResolveEnvRefs_FieldRefs` in `pkg/virtualkubelet/execute_env_fieldref_test.go` (added by the patch; `mise run test:interlink`) |
| **11** | `interlink-hq/interLink` | [`0005-pod-ip-from-plugin-status.patch`](patches/interlink/0005-pod-ip-from-plugin-status.patch) | The plugin's status response is decoded into `types.PodStatus`, which has no IP fields, so the virtual kubelet sets every pod's `status.podIP` and `hostIP` from its own configured `PodIP`; pods on remote VMs report the node's placeholder address. Upstream: not yet reported. | `PodStatus` gains optional `podIP` and `podIPs` fields, and `checkPodsStatus` copies them to the pod's `podIP`, `podIPs`, and `hostIP` when present; the configured placeholder stays when the plugin omits them. | `TestCheckPodsStatusPodIP` in `pkg/virtualkubelet/execute_pod_ip_test.go` (added by the patch; `mise run test:interlink`) |
| **12** | `ray-project/ray` | [`0001-node-agent-proxy.patch`](patches/ray/0001-node-agent-proxy.patch) | With `RAY_grpc_enable_http_proxy` set, gRPC reaches other nodes through the HTTP CONNECT proxy in `grpc_proxy`, `https_proxy`, or `http_proxy`, but the dashboard's HTTP calls to other nodes' agents (the State API's runtime env query and the job head's job agent client) connect directly, so they fail for workers only the proxy can reach. Upstream: not yet reported. | Adds `NodeAgentConnector`, an aiohttp connector that applies the same proxy and `no_grpc_proxy`/`no_proxy` choice as gRPC and tunnels each proxied connection with `CONNECT`; both sessions use it. Without the gRPC proxy flag, connections are unchanged. | [`tests/ray/test_node_agent_proxy.py`](tests/ray/test_node_agent_proxy.py), [`tests/ray/test_patched_files.py`](tests/ray/test_patched_files.py) (`mise run test:ray`, inside each patched image variant) |
| **26** | `ray-project/ray` | [`0002-unschedulable-timeout.patch`](patches/ray/0002-unschedulable-timeout.patch) | The autoscaler v2 moves an `ALLOCATED` instance to `ALLOCATION_TIMEOUT` after `RAY_AUTOSCALER_RECONCILE_ALLOCATE_STATUS_TIMEOUT_S` (an hour by default) whether its pod cannot be placed or is placed and still pulling its image or waiting for its node to boot. With worker groups ranked by Ray `priority`, a short timeout drops pods that are about to start and a long one holds the autoscaler on a group with no capacity. Upstream: not yet reported. | The KubeRay cloud provider marks a worker pod that has no node and either keeps scheduling gates (such as Kueue's admission gate) or has `PodScheduled=False` with reason `Unschedulable`, and the reconciler times out such an instance after `RAY_AUTOSCALER_RECONCILE_UNSCHEDULABLE_TIMEOUT_S` (default 120, capped at the allocate timeout). A pod bound to a node keeps the allocate timeout. | [`tests/ray/test_unschedulable_timeout.py`](tests/ray/test_unschedulable_timeout.py), [`tests/ray/test_patched_files.py`](tests/ray/test_patched_files.py) (`mise run test:ray`, inside each patched image variant) |
| **13** | `kubernetes-sigs/kueue` | [`0005-topology-aware-reclaim.patch`](patches/kueue/0005-topology-aware-reclaim.patch) | Preemption takes victims lowest priority first and stops once each borrowing ClusterQueue is back at its nominal quota. When those victims sit in different topology domains, the freed capacity is scattered, the plan fails the TAS check, and nothing is preempted: a workload that needs a whole node or rack stays pending even though freeing one domain was allowed. Applies to Classic and Fair Sharing preemption. Upstream: [issue #10815](https://github.com/kubernetes-sigs/kueue/issues/10815), [draft PR #17834](https://github.com/kubernetes-sigs/kueue/pull/17834). | When ordinary preemption frees enough quota but no topology placement, and fails at every pod count partial admission tries, retries once at the full count. The retry raises a priority ceiling through the candidates' priorities and starts at the first one, found by bisection, where removing every candidate at or below it frees the quota and a placement; removing more never frees less, so no victim set with a lower highest-priority victim exists, however many domains there are. It checks which candidates the strategies may take by removing their quota from the snapshot and asking Kueue's own resource tree whether each ClusterQueue and Cohort below the shared Cohort still borrows, so guaranteed quota, lending limits, and nested Cohorts count exactly as the strategies count them. At that ceiling each topology leaf offers the occupants its lenders may give up together, chosen from the most expensive down; the retry frees the cheapest leaves first, and when the strategy's cheapest-first order would use up a lender before an occupant the placement needs, keeps only the occupants the placement needs. It runs the preemption strategy with each placement's victims ahead of priority for up to 8 placements, skipping without an evaluation those whose victims the lenders may not give up in any order, and keeps the victims that cost the least. Every preemption policy still applies, and each attempt runs at most 64 + 8 x (2 x bits(L) + 8) topology searches for L topology leaves (304 at 1024 nodes). Exact: no legal victim set has a lower highest-priority victim than one the retry returns at its starting ceiling, assuming freeing capacity never stops a placement from fitting. Best effort: the lowest next-highest victims and the fewest victims compare only the placements found in greedy leaf order, and a placement whose trimmed victims the lenders reject is skipped even if another subset would pass. A retry that finds no victims is not repeated for the same workload until its effective priority or an admission, eviction, quota, policy, or topology change in its cohort or topology flavors changes; admission fair sharing, configurable preemptions, and the scheduler library integration turn this memory off. Elastic victims are evicted whole, like any other workload; with patch 0010 the retry still counts their whole usage, since the strategy evicts a shrunk victim whole when its node is needed ([contract](patches/kueue/contract.md)). Known limitation: the retry runs only at the full count, so a reduced count that only the topology blocks is not retried. | `TestPreemptionReclaimsTopologyDomain` in `pkg/scheduler/preemption/preemption_tas_test.go`, `TestTopologyRetryComparesEveryDomain`, `TestTopologyRetryWithDistinctPriorities`, `TestTopologyRetryRemembersFailures`, and `TestTopologyRetryForgetsFailuresAfterPriorityBoost` in `pkg/scheduler/preemption/topology_retry_test.go`, `TestTopologyRetryRespectsReclaimLimits` and `TestTopologyRetryMatchesStrategyLimits` in `pkg/scheduler/preemption/topology_retry_limits_test.go`, `TestTopologyRetryWithPartialAdmission` in `pkg/scheduler/scheduler_tas_topology_retry_test.go`, and the `Topology-aware cohort reclaim` suite in `test/integration/singlecluster/tas/tas_preemption_topology_test.go` (added by the patch; `mise run test:kueue` and `mise run test:kueue-integration`) |
| **19** | `kubernetes-sigs/kueue` | [`0006-elastic-flavor-on-pods.patch`](patches/kueue/0006-elastic-flavor-on-pods.patch) | An elastic RayCluster worker group admitted with no pods may move to another flavor when it scales up (`ElasticJobsViaWorkloadSlicesFlavorChangeFromZero`), but the first admission put the first flavor's node labels and tolerations on the job template, and every later Pod is created from it. The Pods of the moved group then run on nodes of the wrong flavor, and a Pod whose template label conflicts with the new flavor's cannot be fixed in place, because the API server lets a gated Pod only gain nodeSelector keys. No upstream issue found. | With the gate on, the job reconciler leaves the flavors' node labels and tolerations off the job template when it starts an elastic job, as `deferAdmissionCheckNodeSelectorsToPods` does for ProvisioningRequest selectors, and the ElasticJobUngater adds those of the flavors the active slice assigns to each Pod just before it removes the gate. Only PodSets whose template carries the elastic scheduling gate are deferred, since the ungater handles no other Pods (a RayJob submitter or a SparkApplication keeps its placement). The reconciler marks such a Workload with the `kueue.x-k8s.io/flavor-placement-on-pods` annotation when it builds it, so a ConcurrentAdmission variant and every later slice carry it, and the ungater keeps adding the placement when the gate is turned off. A gated Pod created before the active slice whose older template gave it a conflicting nodeSelector value is deleted once, so its owner recreates it; a Pod created after the slice, whose conflict comes from the job's current template, stays gated and gets a Warning event on the Workload, because deleting it would only make the owner recreate it. With the gate off and no marker, nothing changes. | [`tests/scenarios/kueue/06-elastic-flavor-from-zero/01-scale-up-from-zero`](tests/scenarios/kueue/06-elastic-flavor-from-zero/01-scale-up-from-zero)<br>`TestFlavorPlacementOnPods` in `pkg/controller/elasticjobs/elastic_flavor_placement_test.go`, `TestDeferFlavorPlacementToPods` in `pkg/controller/jobframework/reconciler_flavor_placement_test.go`, and the `RayCluster elastic flavor change from zero` spec in `test/integration/singlecluster/controller/jobs/raycluster/raycluster_controller_elastic_flavor_test.go` (added by the patch; `mise run test:kueue` and `mise run test:kueue-integration`) |
| **20** | `kubernetes-sigs/kueue` | [`0007-elastic-template-restamp.patch`](patches/kueue/0007-elastic-template-restamp.patch) | Kueue stamps the `kueue.x-k8s.io/podset` label and the slice name annotation on a running elastic RayCluster's templates once, when it starts the cluster. Re-applying the manifest with `kubectl apply`, GitOps, or a JSON merge patch replaces the atomic `workerGroupSpecs` list and drops both, so every worker KubeRay creates afterwards stays gated forever, and a manifest without the scheduling gate is rejected. Vanilla Kueue has the same defect. No upstream issue found. | The RayCluster defaulting webhook runs on updates too. On every write to an elastic RayCluster it adds the scheduling gate to the head and worker templates; while the cluster runs, it also sets each template's PodSet label and the slice name annotation, fills in the Workload annotation when Pod scheduling is tracked and the template lacks it (it never changes one the cluster has, since a template change makes KubeRay with `upgradeStrategy: Recreate` delete every Pod), restores the topology scheduling gate and the unconstrained-topology annotation of a PodSet with a topology assignment, and, when the chain did not start with the placement on the Pods, the flavors' node labels and tolerations, from the cluster's newest unfinished, unevicted Workload that holds quota, so it never reads a finished or earlier chain's slice. The webhook answers the write itself, so Kueue never races the user's write, deletes no pod, and adds nothing a later re-apply would remove; applying its own output again changes nothing, so a tool that re-applies cannot loop. The live templates then differ from the manifest in the gate, the label `kueue.x-k8s.io/podset`, the annotation `kueue.x-k8s.io/workload-slice-name`, and sometimes the node labels and tolerations of the flavor: a GitOps tool should diff with server-side apply (the dry run runs the webhook, so the diff is empty) or ignore those paths in `workerGroupSpecs[].template` and `headGroupSpec.template`. Non-elastic clusters get nothing; a suspended elastic cluster gets only the gate. The release manifests register the webhook for `CREATE` only, so the deployment adds `UPDATE` to the `mraycluster.kb.io` rule ([setup](#raycluster-webhook-operations)). | [`tests/scenarios/kueue/05-elastic-template-reapply/01-reapply-worker-group`](tests/scenarios/kueue/05-elastic-template-reapply/01-reapply-worker-group)<br>`TestRestampElasticTemplatesOnUpdate` in `pkg/controller/jobs/raycluster/elastic_template_restamp_test.go` and the `RayCluster elastic template re-apply` specs in `test/integration/singlecluster/controller/jobs/raycluster/reapply/raycluster_reapply_test.go` (added by the patch; `mise run test:kueue` and `mise run test:kueue-integration`) |
| **21** | `kubernetes-sigs/kueue` | [`0008-partial-preemption-reclaim-targets.patch`](patches/kueue/0008-partial-preemption-reclaim-targets.patch) | Upstream preemption can only evict an elastic RayCluster whole: Kueue has no way to stop some of its workers and release only their quota, so a preemptor that needs a few pods takes the whole cluster down. Upstream: [PR #17484](https://github.com/kubernetes-sigs/kueue/pull/17484) (draft), [KEP-975](https://github.com/kubernetes-sigs/kueue/pull/14589). | Adds the `PartialPreemption` gate (alpha, off by default) and acts on the `kueue.x-k8s.io/reclaim-target-counts` Workload annotation that the preemption patch writes ([contract](patches/kueue/contract.md#annotation-keys)). The job reconciler deletes the running workers above the target in whole `ray.io/worker-group-replica-name` replicas, lowest `controller.kubernetes.io/pod-deletion-cost` first, then newest, without changing `replicas`; the ElasticJobUngater keeps the recreated workers gated and raises `status.reclaimablePods` only once the running workers are at or below the target, which is when the quota is released. An autoscaler scale-down keeps the Workload charged for the target ([rule](patches/kueue/contract.md#scale-down-after-a-reclaim)), and the target is cleared once the Workload no longer holds quota. | `TestDeletePodGroupsAboveCounts` and `TestEnsureWorkloadSlicesReclaimScaleDown` in `pkg/workloadslicing/partial_preemption_test.go`, `TestReconcileReclaimTargets` in `pkg/controller/elasticjobs/reclaim_targets_test.go`, `TestClearReclaimTargets` and `TestReconcileClearsReclaimTargetsOnceQuotaIsReleased` in `pkg/controller/core/reclaim_targets_test.go`, `TestReconcileStopsWorkersAboveReclaimTargets`, `TestReconcileClearsReclaimedPodsWhenEvictionReleasesQuota` and `TestPodsReadyWithPartialPreemption` in `pkg/controller/jobs/raycluster/partial_stop_test.go`, the helpers' tests in `pkg/workload/partial_preemption_test.go`, and the "RayCluster with partial preemption" specs in `test/integration/singlecluster/controller/jobs/raycluster/raycluster_controller_partial_preemption_test.go` (all added by the patch; `mise run test:kueue` and `mise run test:kueue-integration`) |
| **22** | `kubernetes-sigs/kueue` | [`0009-partial-preemption-floors.patch`](patches/kueue/0009-partial-preemption-floors.patch) | Partial preemption needs to know how far a victim may shrink, and Kueue's only per-PodSet minimum, `minCount`, means the partial admission floor and the scale-up baseline. Using it for preemption made a Workload's admission rules and its shrink limit change together, which broke running jobs when one was edited. | With `PartialPreemption` on, the job reconciler writes two Workload annotations when it builds a Workload for an elastic RayCluster: `kueue.x-k8s.io/reclaim-min-counts` (the fewest pods each worker group may keep) and `kueue.x-k8s.io/podset-count-steps` (the pod count it shrinks and grows by), as `<podSet>=<count>` lists sorted by name. A single-host worker group has floor `minReplicas` and step 1. The floor is written only for a cluster with the `kueue.x-k8s.io/elastic-job-scale-up-strategy: partial` annotation (and `ElasticJobsViaWorkloadSlicesWithPartialReplicaScaleUp` on), because upstream creates no scale-up probe for other clusters and a shrunk one could never grow back; the others get steps but no floor and are evicted whole. The head, non-elastic RayClusters, and elastic RayJobs and RayServices get no entry and are only evicted whole; patch 0012 adds the multi-host worker groups. `EnsureWorkloadSlices` keeps both annotations current on every active slice, with each floor capped at that slice's PodSet count, so editing `minReplicas` updates an admitted slice even while a pending scale-up exists; the update touches metadata only, so a Workload admitted by an older release, with its `minCount`, stays admitted. Workload `minCount` is never set or read for this. With the gate off nothing is written or updated. Interfaces `JobWithReclaimMinCounts` and `JobWithPodSetCountSteps` and the accessors `ReclaimMinCounts` and `PodSetCountSteps` are defined in [the contract](patches/kueue/contract.md#go-interfaces). | `TestRayClusterReclaimFloorsAndSteps`, `TestConstructWorkloadReclaimFloors`, and `TestRayJobAndRayServiceHaveNoFloors` in `pkg/controller/jobs/raycluster/`, `TestEnsureWorkloadSlicesReclaimFloors` and `TestEnsureWorkloadSlicesReclaimFloorsOnEverySlice` in `pkg/workloadslicing/reclaim_floors_test.go`, `pkg/workload/reclaim_floors_test.go`, and the `RayCluster reclaim floors` suite in `test/integration/singlecluster/controller/jobs/raycluster/raycluster_controller_reclaim_floors_test.go` (`mise run test:kueue` and `mise run test:kueue-integration`) |
| **23** | `kubernetes-sigs/kueue` | [`0010-partial-preemption-search.patch`](patches/kueue/0010-partial-preemption-search.patch) | Preemption can only evict a victim whole, so an elastic workload loses every pod even when a few would make room. Kueue also has no way to model a victim that keeps some pods: each place that takes a victim out of the scheduling snapshot (the search, its fill-back, the in-cycle fit check, the overlap recompute, the TAS planner, the flavor oracle and the topology retry) treats it as fully freed, which is how earlier partial preemption patches over-admitted preemptors one site at a time. Upstream: [draft PR #17484](https://github.com/kubernetes-sigs/kueue/pull/17484), [KEP-975 draft](https://github.com/kubernetes-sigs/kueue/pull/14589). | Behind the `PartialPreemption` gate, off by default. A preemption target can carry `Remaining`, the victim's `workload.Info` with each shrunk PodSet's quota scaled down and its topology usage kept, and every snapshot site removes and restores targets through one seam (`RemoveFrom`, `AddTo`, `FreedUsage`, `SimulateRemoval`, `SimulateUsageRemoval`, `EvictedWorkloads`), so none of them needs to know about shrinking. The classical strategy offers a victim with `kueue.x-k8s.io/reclaim-min-counts` shrunk to its floors, rounded up to its `kueue.x-k8s.io/podset-count-steps`. When the candidates run out without a fit, it evicts the shrunk targets whole one at a time on the same target. Fill-back first restores whole victims, then grows each shrunk victim back in steps while the preemptor still fits. A victim whose reclaim target is still pending is offered right after the evicted candidates at that target, its other PodSets whole, and when it is escalated fill-back can still shrink every PodSet with a floor; once the target is 5 minutes old the victim is ordered like any other candidate and evicted whole. A victim shrunk earlier in the same cycle is not offered again. The topology retry counts every candidate's whole usage, since the strategy evicts a shrunk victim whole when its node is needed. A partial target is issued as `kueue.x-k8s.io/reclaim-target-counts`, never raising a target already set, plus the preemptor and the time it was last lowered, with no preemption expectation, so issuing it again writes nothing. Fair sharing and configurable preemption still evict whole. It reads the floors and steps patch 0009 writes, and writes the reclaim target patch 0008 acts on. | `TestPartialPreemptionSearch`, `TestPartialPreemptionSearchProperties` (a randomized property test), `TestPartialPreemptionFairSharingYieldsWholeTargets`, `TestPartialPreemptionConfigurableRulesYieldWholeTargets`, `TestPartialPreemptionSeam`, `TestIssuePartialPreemption`, `TestSetReclaimTargetNeverRaisesATarget`, `TestPreemptionOracleCountsShrunkTargets`, `TestPartialPreemptionSkipsAVictimShrunkThisCycle` and `TestPartialPreemptionTopologyRetryFreesAShrinkableVictimsNode` in `pkg/scheduler/preemption/partial_preemption*_test.go`, and `TestFitsCountsShrunkVictimsRemainingPods`, `TestPartialPreemptionWithTAS` and `TestPartialPreemptionTwoPreemptorsInOneCycle` in `pkg/scheduler/scheduler_partial_preemption_test.go` (added by the patch; `mise run test:kueue`) |
| **24** | `kubernetes-sigs/kueue` | [`0011-elastic-regrow-after-reclaim.patch`](patches/kueue/0011-elastic-regrow-after-reclaim.patch) | Partial preemption shrinks an elastic victim through a reclaim target and `reclaimablePods`, but nothing grows it back: its job still asks for the original count and its slice's spec count matches it, so no KEP-12100 scale-up probe is created. Without more changes a probe would also go wrong in four ways: a reclaim lowers the slice chain's admitted level, so a later probe can recompute an earlier probe's name and fail with `already exists` on every reconcile; a pending probe left by a partial scale-up could be admitted while the target is still pending, handing back the quota being reclaimed, or race the preemptor for the released quota; a scale-down during a pending probe updates the probe instead of the admitted slice, which keeps its charge and never stops the pods above its target; and a suspended job whose only admitted slice has a pending probe never starts, while that slice holds quota. Upstream: [draft PR #17484](https://github.com/kubernetes-sigs/kueue/pull/17484) (probe names), the open probe-versus-preemptor question in the [KEP-975 draft](https://github.com/kubernetes-sigs/kueue/pull/14589). | Reclaim targets are only written with the `PartialPreemption` gate on, off by default, but regrowth and the hold follow the targets, so they keep working after the gate is turned off; the patch also drops the gate from the 0008 stopper and in-place scale-down rule for the same reason. Once a slice's reclaim target is released, `EnsureWorkloadSlices` creates a scale-up probe when the job asks for more pods than the target, comparing the job's count with the target rather than with the slice's spec count, and only for jobs with `kueue.x-k8s.io/elastic-job-scale-up-strategy: partial`. Probes are named after the predecessor slice's UID. A probe starts from what its predecessor runs after the reclaim, in its `minCount` and in the scheduler's must-grow baseline, so it can regrow part of the way. During nomination, the scheduler holds a replacement slice back while its predecessor's reclaim target is pending, or while the preemptor recorded in `kueue.x-k8s.io/reclaim-preemptor` is pending, for at most the 5-minute reclaim timeout after `kueue.x-k8s.io/reclaim-requested-at` and not once that preemptor was evicted since, other than by deactivation; a held slice waits as inadmissible, in StrictFIFO queues too, and is retried after the next admission and every 5 seconds. A scale-down that no longer grows past the admitted slice finishes the pending probe and lowers the admitted slice in place. While a probe is pending, the job reconciler acts on the admitted slice when the job is suspended, so it starts (also with the gate off, for Workloads that an earlier release admitted with `minCount` = `minReplicas`), or when that slice's target is pending, so its pods are stopped. Kueue never writes the job's `replicas`. The patch also makes the 0008 spec of an autoscaler scale-down of a partially admitted victim record its preemptor with the target, as patch 0010 does. | `TestEnsureWorkloadSlicesRegrowAfterReclaim`, `TestEnsureWorkloadSlicesScaleDownDuringPendingProbe` and `TestAfterReclaimBaseline` in `pkg/workloadslicing/regrow_after_reclaim_test.go`, `TestConstructWorkloadAfterReclaim` and `TestSliceToReconcile` in `pkg/controller/jobframework/regrow_after_reclaim*_test.go`, `TestHoldBackRegrowth` and `TestRegrowthStartsFromTheAfterReclaimCount` in `pkg/scheduler/regrow_after_reclaim_test.go`, and the `RayCluster regrowth after a partial preemption reclaim` suites, with the gate on and off, in `test/integration/singlecluster/controller/jobs/raycluster/raycluster_controller_regrow_after_reclaim_test.go` (added by the patch; `mise run test:kueue` and `mise run test:kueue-integration`) |
| **25** | `kubernetes-sigs/kueue` | [`0012-multi-host-partial-scale-up.patch`](patches/kueue/0012-multi-host-partial-scale-up.patch) | A multi-host worker group runs whole replicas of `numOfHosts` pods, and KubeRay rounds `replicas` down, but partial admission grants any pod count between the baseline and the request. Kueue can charge 5 pods for a group whose replicas hold 2 pods each, while KubeRay creates 2 replicas, 4 pods. Checked on the unrounded count, a scale-up from 4 pods that is granted 5 counts as growth, so the slice is admitted at the size it replaces and the cluster recreates it again and again. The ungater also picks gated pods by name, which starts one host of each of two replicas instead of one whole replica. | With `ElasticJobsViaWorkloadSlicesWithPartialReplicaScaleUp` on, the job reconciler writes `kueue.x-k8s.io/podset-count-steps` with step `numOfHosts` for each multi-host worker group of an elastic RayCluster, whether or not `PartialPreemption` is on, and with `PartialPreemption` on it also writes the multi-host floor `minReplicas` x `numOfHosts` that patch 0009 leaves out. The scheduler's partial admission reduces step counts instead of pod counts, so a grant is always a whole number of steps, the baseline rounds up to a step, and a scale-up must beat the baseline in whole steps: a slice granted 4 of 8 pods with room for 5 stays pending until room for 6. For a PodSet with a step above 1 the ungater starts whole `ray.io/worker-group-replica-name` groups, completing a started group first, starting a new group only once all its `numOfHosts` pods exist, and never part of a group. Elastic RayJobs and RayServices get no steps. Steps of 1, a Workload without the annotation, and the gate off leave admission as before. | `TestSteppedPodSetReducer*` in `pkg/scheduler/flavorassigner/podset_reducer_steps_test.go`, `TestPartialScaleUpSteps` in `pkg/scheduler/partial_scale_up_steps_test.go`, `TestUngateWholeReplicaGroups` in `pkg/controller/elasticjobs/ungate_whole_groups_test.go`, `TestRayClusterReclaimFloorsAndSteps` and `TestConstructWorkloadReclaimFloors` in `pkg/controller/jobs/raycluster/reclaim_floors_test.go`, and the `RayCluster partial scale-up of a multi-host worker group` suite in `test/integration/singlecluster/controller/jobs/raycluster/raycluster_controller_multi_host_scaleup_test.go` (`mise run test:kueue` and `mise run test:kueue-integration`) |
| **27** | `kubernetes-sigs/kueue` | [`0013-flavor-split-podsets.patch`](patches/kueue/0013-flavor-split-podsets.patch) | A Workload PodSet has one flavor per resource, and a scale-up slice keeps each PodSet on the flavor its running pods use. An elastic worker group whose growth does not fit on that flavor stays pending, even when the next flavor in the ClusterQueue has room, so a group admitted on a reserved flavor cannot overflow onto spot capacity. Creating a second Workload for the overflow would break Kueue's one-Workload-per-job rule ([KEP-77](https://github.com/kubernetes-sigs/kueue/tree/main/keps/77-dynamically-sized-jobs)). Upstream: [KEP-12100](https://github.com/kubernetes-sigs/kueue/tree/main/keps/12100-partial-scaleup-for-elasticjob) models a job on two flavors as two PodSets of one Workload. | With `ElasticJobsViaWorkloadSlicesFlavorSplit` on (off by default; it requires `ElasticJobsViaWorkloadSlicesFlavorChangeFromZero`), when the scheduler refuses a pending scale-up slice because its worker group's running pods keep it on a full flavor while the added pods would fit on another one (the flavor assigner says so in the slice's message), the job reconciler keeps each running PodSet at its count and flavor and moves the added pods to a split entry of the same Workload, `<group>--2`, `<group>--3`, and so on, marked with the template annotation `kueue.x-k8s.io/flavor-split-of: <group>`. The scheduler gives the new entry the first flavor in the ClusterQueue that fits, so a group that still fits on its flavor stays one entry. The ElasticJobUngater starts the group's gated pods in its own entry first, then in each split entry, writing the entry name in the pod's `kueue.x-k8s.io/podset` label with that entry's flavor node labels and tolerations; a pod keeps its entry for life. Later slices carry the entries, grow the newest one, and drop an entry once it is at 0. A scale-down shrinks the entry whose pods the job's controller deleted, the Ray autoscaler's `workersToDelete` for a RayCluster, and among pods not yet started the newest entries first; until the pods are gone the slice stays charged for them. Split entries get floor 0 and their group's step, so partial preemption of one flavor stops only the pods on it and the cluster keeps running. PodSets whose topology request constrains placement and Workloads with 8 PodSets are never split. Patch 0014 adds ordered fill with whole count steps. With `SCALEGATE_FLAVOR_SPLIT=true` the KubeRay ScaleGate caps `maxReplicas` at the sum of the flavors and sums the admitted entries of each worker group. Existing split entries keep working after the gate is turned off. | `TestEntryCountsForJob`, `TestCarrySplitEntries`, `TestSplitGrowth`, `TestEnsureWorkloadSlicesFlavorSplit` and `TestDeletePodGroupsAboveCountsKeepsOtherEntries` in `pkg/workloadslicing/flavor_split_test.go`, `TestUngateSplitEntries` in `pkg/controller/elasticjobs/ungate_split_entries_test.go`, `TestGrowthFitsOtherFlavorReason` and `TestRayJobScaleUpDefect` in `pkg/scheduler/flavorassigner/flavor_split_test.go`, `TestConstructWorkloadCarriesSplitEntries` and `TestGetPodSetsInfoFrom*SkipsSplitEntries` in `pkg/controller/jobframework/flavor_split*_test.go`, `TestPartialPreemptionShrinksOnlyTheSplitEntryOnTheNeededFlavor` in `pkg/scheduler/preemption/flavor_split_test.go` (`mise run test:kueue`), and [`kueue/07-flavor-split-podsets/01-flavor-split`](tests/scenarios/kueue/07-flavor-split-podsets/01-flavor-split), [`02-regrow-onto-other-flavor`](tests/scenarios/kueue/07-flavor-split-podsets/02-regrow-onto-other-flavor), [`03-cpu-head-gpu-workers`](tests/scenarios/kueue/07-flavor-split-podsets/03-cpu-head-gpu-workers), and [`04-rayjob-gpu-classes`](tests/scenarios/kueue/07-flavor-split-podsets/04-rayjob-gpu-classes) |
| **28** | `kubernetes-sigs/kueue` | [`0014-greedy-flavor-fill.patch`](patches/kueue/0014-greedy-flavor-fill.patch) | A probe can skip unused capacity on the first flavor when its full count fits only on a later flavor. | Under the flavor-split gate, elastic workers fill eligible flavors in order, with a running entry growing on its flavor first: 0-to-24 with 15 free slots on A, or 8-to-24 with 7 free slots on A, yields A x15 and B x9. Steps round down; reclaim floors, borrowing policy, lending limits and earlier PodSets' usage constrain each grant. Initial nonzero slices also fill; workers need neither `MinCount` nor the partial strategy. RayJobs reuse worker reclaim floors and replica steps, preserving the head and other entries during partial reclaim. The pure assigner records counts in a refusal note; only the job reconciler rewrites spec. If aggregate free quota cannot cover the full count, existing partial admission remains in charge. Entry reclaim, LIFO shrink, merge-back and the reclaim hold retain their behavior; see [R9](patches/kueue/contract.md#flavor-split-podsets). | `TestGreedySplit`, `TestStaleGreedyQuotaProposal`, `TestMaterializeGreedySplit`, `TestReclaimRayJobWorkers`, `TestUngateSplitWholeReplicas`, the scheduler integration spec "Greedy flavor fill", and the [RayJob GPU-class scenario](tests/scenarios/kueue/07-flavor-split-podsets/04-rayjob-gpu-classes) |

### interLink Upstream Issue Draft

The following issue for `interlink-hq/interLink` covers patches 7 and 8. It is drafted here and not yet filed.

<details>
<summary><b>Virtual kubelet panics or updates the wrong container status in checkPodsStatus</b></summary>

**Version:** 0.6.2 (`pkg/virtualkubelet/execute.go`)

**1. Nil dereference when a failed pod has a non-terminated container status**

When every container the plugin reports has terminated and at least one exited non-zero, `checkPodsStatus` marks the pod `Failed` and then rewrites the reason on every in-cluster container status:

```go
for i := range podRefInCluster.Status.ContainerStatuses {
    podRefInCluster.Status.ContainerStatuses[i].State.Terminated.Reason = failedReason
}
```

`CreatePod` creates a status for every spec container, but the completion check compares the terminated count with the number of containers the plugin reported. If the plugin omits a container (for example one excluded from offloading), that status is still `Waiting` or `Running`, `State.Terminated` is nil, and the virtual kubelet panics while holding `podsMu`. The pod is re-polled after restart, so the node crash-loops.

Expected: only statuses whose `State.Terminated` is set get the failure reason.

**2. Status update lands on index 0 when the remote container name is unknown**

`handleContainersUpdate` (and the same code in `handleInitContainersUpdate`) looks up the remote status by name, appends it when nothing matches, but keeps `index := 0`. Every following write (`Ready`, `State.Running`, `State.Terminated.Reason`) goes to the first container's status. A running unknown container marks the first container Ready and Running; a terminated one panics on the first container's nil `State.Terminated`.

Expected: write to the entry that was found or appended. We use `len-1` after appending names that belong to the pod spec, and skip writing names outside the pod spec while still counting them toward the pod phase, since a status the spec cannot account for confuses clients that pair statuses with spec containers.

**Reproduction:** unit tests in [`patches/interlink`](https://github.com/simonepri/elastic-kueue-kuberay-patches/tree/main/patches/interlink) panic or fail on 0.6.2 and pass with the fix.

</details>

### Distributed Multi-Pool & Multi-Cloud Test Scenarios

The test scenarios under [`tests/scenarios/distributed`](tests/scenarios/distributed) validate end-to-end multi-pool worker orchestration across heterogeneous infrastructure:

| Scenario | Path | Key Capabilities Tested |
| :--- | :--- | :--- |
| **01-virtual-worker-pool** | [`tests/scenarios/distributed/01-virtual-worker-pool`](tests/scenarios/distributed/01-virtual-worker-pool) | Heterogeneous worker groups spanning local and virtual GPU node pools, standard topology label routing, and remote spot interruption graceful drain without head eviction. |
| **02-multipool-scalegate** | [`tests/scenarios/distributed/02-multipool-scalegate`](tests/scenarios/distributed/02-multipool-scalegate) | Multi-pool ScaleGate quota clamping, independent pool headroom enforcement, and asymmetric autoscaling across local vs. remote pools. |
| **03-spot-market-dry-cascade** | [`tests/scenarios/distributed/03-spot-market-dry-cascade`](tests/scenarios/distributed/03-spot-market-dry-cascade) | Multi-flavor fallback when primary spot pool experiences zero availability (ICE / market dry), automatically cascading workloads to secondary spot/burst regions without deadlock. |
| **04-spot-eviction-below-min-viable** | [`tests/scenarios/distributed/04-spot-eviction-below-min-viable`](tests/scenarios/distributed/04-spot-eviction-below-min-viable) | Minimum viable threshold protection during spot storms, clamping contraction so worker groups never drop below `minReplicas`. |
| **05-spot-elastic-reexpansion** | [`tests/scenarios/distributed/05-spot-elastic-reexpansion`](tests/scenarios/distributed/05-spot-elastic-reexpansion) | Self-healing two-way spot elasticity across heterogeneous pools, gracefully yielding spot workers during high-priority bursts and automatically re-expanding when capacity clears without head disruption. |
| **06-quota-exhaustion-prevention** | [`tests/scenarios/distributed/06-quota-exhaustion-prevention`](tests/scenarios/distributed/06-quota-exhaustion-prevention) | Hard cloud account quota enforcement (e.g. AWS VcpuLimitExceeded / GPU quota ceiling) clamped preemptively by ScaleGate to prevent cloud API throttling and pending pod thrashing. |
| **08-gcp-spot-multi-cloud** | [`tests/scenarios/distributed/08-gcp-spot-multi-cloud`](tests/scenarios/distributed/08-gcp-spot-multi-cloud) | Multi-cloud spot worker orchestration spanning AWS Spot (`g5.2xlarge` in `us-east-1`) and GCP Spot (`a2-highgpu-1g` in `us-central1`); validates GCP 30-second preemption isolation while preserving AWS workers. |
| **09-shared-kueue-fleet-fairness** | [`tests/scenarios/distributed/09-shared-kueue-fleet-fairness`](tests/scenarios/distributed/09-shared-kueue-fleet-fairness) | Two-tier fleet queue architecture: autonomous cell-local compute (Tier 1) and centralized spot fleet fair sharing via Shared Kueue cohort on the control cluster (Tier 2); validates dynamic borrowing, fair-share cohort reclaim, and ScaleGate fleet clamping without the control cluster running user pods. |
| **10-interlink-cloudvm-virtual-kubelet** | [`tests/scenarios/distributed/10-interlink-cloudvm-virtual-kubelet`](tests/scenarios/distributed/10-interlink-cloudvm-virtual-kubelet) | End-to-end hybrid Ray cluster bursting onto an InterLink Virtual Kubelet node (`interlink-cloudvm-plugin`) under realistic network and provisioning latencies (cold-start VM boot/pull delay, GCS RPC timeout tolerance, and 15s termination grace latency without double-counted quota or head eviction). |
| **12-interlink-cloudvm-partial-preemption** | [`tests/scenarios/distributed/12-interlink-cloudvm-partial-preemption`](tests/scenarios/distributed/12-interlink-cloudvm-partial-preemption) | Partial preemption of scenario 10's hybrid cluster under a 15s termination grace period, and its re-expansion after the preemption and after a spot interruption. |

Scenarios 05, 09, and 12, and the scenarios under [`tests/scenarios/kueue/01-partial-preemption`](tests/scenarios/kueue/01-partial-preemption) and [`tests/scenarios/kueue/02-elastic-reexpansion`](tests/scenarios/kueue/02-elastic-reexpansion), carry the label `partial-preemption: required`. CI runs the scenarios twice: once with the default gates, which leaves those out, and once with every gate of [Feature Gates](#feature-gates) on, `PartialPreemption` included, which runs them all. They assert what [the contract](patches/kueue/contract.md#acceptance-tests) asks: the victim keeps `replicas`, its pods above the reclaim target are deleted and recreated gated, and the preemptor is admitted only once they are gone. Scenario 12 holds the steps of scenario 10 that need partial preemption or re-expansion, so 10's spot interruption steps run in both legs. [`kueue/01-partial-preemption/04-ray-autoscaler`](tests/scenarios/kueue/01-partial-preemption/04-ray-autoscaler) runs the same shrink, regrowth, and an autoscaler scale-down of a shrunk cluster with the Ray in-tree autoscaler on, and checks that the pods holding resources never exceed the quota.

---

## Dual Versioning Scheme

Images published by this repository use a compound tag format:

$$\text{Image Tag} = \langle\text{upstream-version}\rangle\text{-p}\langle\text{patch-version}\rangle$$

Examples:
- `ghcr.io/simonepri/kueue:v0.20.2-p0.2.0`
- `ghcr.io/simonepri/kuberay-operator:v1.7.1-p0.2.0`
- `ghcr.io/simonepri/interlink-virtual-kubelet:0.6.2-p0.1.0`
- `ghcr.io/simonepri/ray:2.59.0-py313-p0.1.0` (the upstream image tag, including its Python suffix, then the patch version)

The Ray patches are published on top of each upstream Ray image listed in [`patches/ray/variants.json`](patches/ray/variants.json), with the same platforms:

| Upstream base image | Patched image | Platforms |
| --- | --- | --- |
| `rayproject/ray:2.59.0-py313` | `ghcr.io/simonepri/ray:2.59.0-py313-p<patch-version>` | `linux/amd64`, `linux/arm64` |
| `rayproject/ray:2.59.0-py313-gpu` | `ghcr.io/simonepri/ray:2.59.0-py313-gpu-p<patch-version>` | `linux/amd64` |
| `rayproject/ray:2.59.0-py313-cu126` | `ghcr.io/simonepri/ray:2.59.0-py313-cu126-p<patch-version>` | `linux/amd64` |

CI runs the Ray unit tests inside every variant, including a check that the image ships each patched file unchanged.

When [Renovate](renovate.json) detects an upstream release, it opens a PR updating the upstream baseline. Once merged, [Release Please](release-please-config.json) increments the patch version independently.

---

## Deployment & Installation

You can deploy the patched controllers into any existing Kubernetes cluster using either Helm or official manifests with image overrides.

### 1. KubeRay Operator

Deploy the patched KubeRay operator with the official Helm chart:

```bash
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm repo update

helm install kuberay-operator kuberay/kuberay-operator \
  --version v1.7.1 \
  --namespace default \
  --set image.repository=ghcr.io/simonepri/kuberay-operator \
  --set image.tag=v1.7.1-p0.2.0
```

When Kueue runs with `ElasticJobsViaWorkloadSlicesFlavorSplit` (patch 0013), also set the operator's `SCALEGATE_FLAVOR_SPLIT` environment variable to `true` (`--set env[0].name=SCALEGATE_FLAVOR_SPLIT --set-string env[0].value=true`). ScaleGate then caps a worker group's `maxReplicas` at the sum of the flavors of each resource group rather than the largest one, since Kueue may run the group on several flavors at once; without it the autoscaler cannot ask for more workers than one flavor holds.

#### Required RBAC Permissions
The patched operator requires permissions to read Kueue `ClusterQueue`, `LocalQueue`, `Cohort`, and `Workload` resources (for ScaleGate quota clamping). The spot interruption controller only runs when the operator's `KUBERAY_SPOT_INTERRUPTION_NOTICES` environment variable is `true`; only then does it need the `ConfigMap` permissions below, and it caches only ConfigMaps labelled `test.k8s.io/event=spot-interrupted`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kuberay-operator-extra
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["kueue.x-k8s.io"]
    resources: ["clusterqueues", "localqueues", "cohorts", "workloads"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kuberay-operator-extra
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kuberay-operator-extra
subjects:
  - kind: ServiceAccount
    name: kuberay-operator
    namespace: default
```

---

### 2. Kueue Controller Manager

Deploy Kueue using either Helm or the official release manifests:

**Using Helm:**
```bash
helm install kueue oci://registry.k8s.io/charts/kueue \
  --version v0.20.2 \
  --namespace kueue-system --create-namespace \
  --set controllerManager.manager.image.repository=ghcr.io/simonepri/kueue \
  --set controllerManager.manager.image.tag=v0.20.2-p0.2.0 \
  --set 'controllerManager.featureGates[0].name=ConcurrentAdmission' \
  --set 'controllerManager.featureGates[0].enabled=true'
```

**Using Official Manifests:**
```bash
curl -sL "https://github.com/kubernetes-sigs/kueue/releases/download/v0.20.2/manifests.yaml" | \
  sed -e "s|registry.k8s.io/kueue/kueue:v0.20.2|ghcr.io/simonepri/kueue:v0.20.2-p0.2.0|g" | \
  kubectl apply --server-side -f -
kubectl patch deployment/kueue-controller-manager -n kueue-system --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--feature-gates=ConcurrentAdmission=true"}]'
```

The Karpenter AdmissionCheck needs the `ConcurrentAdmission` feature gate, because Kueue's scheduler reads the `kueue.x-k8s.io/workload-allowed-resource-flavors` annotation, which the check uses to move a Workload to another flavor, only with that gate. Without it the check reports `Active=False` with reason `FeatureGateDisabled`, and its ClusterQueues admit nothing. Enabling the gate changes nothing for ClusterQueues without `spec.concurrentAdmissionPolicy`. Do not run the check on a ClusterQueue with that policy: its variant Workloads already carry the allowed-flavors annotation, so the check only retries them. Set the gate either with `--feature-gates` or with `featureGates` in the Kueue configuration file, not both, since Kueue refuses to start when both are set.

#### Feature Gates

The patches change no feature gate default. Set these in the Kueue configuration's `featureGates` (or with `--feature-gates`, not both):

| Gate | Set to | Why |
| :--- | :--- | :--- |
| `ConcurrentAdmission` | `true` | The Karpenter AdmissionCheck (patch 0003) moves Workloads between flavors through an annotation that Kueue reads only with this gate. |
| `ElasticJobsViaWorkloadSlicesWithPartialReplicaScaleUp` | `true` | Patch releases up to p0.6.x turned it on in code and gave elastic Workloads a `minCount`. Without the gate, the Workload webhook rejects every update to such a Workload, status updates included. Clusters with the `kueue.x-k8s.io/elastic-job-scale-up-strategy: partial` annotation need it permanently, for partial scale-up. Turn it off only when no job carries that annotation (upstream Kueue sets `minCount` on those jobs' Workloads itself, equal to the job's initial count, and the Workload does not carry the annotation, so with that strategy the query below never prints 0 and the gate stays on permanently) and `kubectl get workloads -A -o json \| jq '[.items[] \| select(.metadata.annotations["kueue.x-k8s.io/elastic-job"] == "true" and all(.status.conditions[]?; .type != "Finished" or .status != "True") and any(.spec.podSets[]; .minCount != null))] \| length'` prints 0 (it skips Finished Workloads, which keep the `minCount` of replaced slices); an elastic cluster drops the old `minCount` at its next scale-up, since an in-place scale-down keeps it, or when it is recreated ([migration](patches/kueue/contract.md#migration-from-p06x)). |
| `ElasticJobsViaWorkloadSlicesFlavorChangeFromZero` | `true`, or leave the `false` default | Patch release p0.6.1 turned it on in code. Patch 0006 puts the new flavor's node labels and tolerations on the Pods of a moved PodSet, and keeps them off the job template, so the gate is a configuration choice again. A cluster started with the gate on carries the `kueue.x-k8s.io/flavor-placement-on-pods` annotation on its Workloads, and the ungater keeps adding the placement after the gate is turned off, so rolling the gate back strands no Pod outside its charged flavor. A cluster started with the gate off keeps the placement on its template, where patch 0007 restores it after a re-apply. |
| `PartialPreemption` | `true` to shrink elastic RayClusters instead of evicting them, or leave unset | Patch 0008 adds this gate ([contract](patches/kueue/contract.md#feature-gate)); Kueue refuses to start with a gate name it does not know. CI runs every scenario with it on, including [`kueue/01-partial-preemption/04-ray-autoscaler`](tests/scenarios/kueue/01-partial-preemption/04-ray-autoscaler), which runs the Ray in-tree autoscaler. With the gate on, `waitForPodsReady` treats an elastic RayCluster whose Workload has a reclaim target as ready once its head Pod is, as `RayClusterHeadPodReady` does, because the workers a shrink recreates stay gated and the cluster may never reach the Ready state; without a target it must still reach the Ready state. Turning the gate off after a reclaim stops new shrinks, but reclaim targets already written keep working until they are cleared: the job reconciler still stops the workers above a pending target, the ElasticJobUngater still caps ungating and releases the quota, an in-place scale-down still keeps the charge right, and a shrunk cluster still regrows through a scale-up probe, held back while its preemptor waits. Only partial preemption itself stops: a later preemptor that needs the victim evicts it whole. One gap remains with the gate off: a probe for a slice with no reclaim target is named after the chain's admitted level again, so in a chain that was reclaimed while the gate was on, a later probe can recompute the name of an earlier, Finished slice and fail with `already exists` on every reconcile. That cluster then cannot scale up; nothing is over-admitted or suspended. Turn the gate back on, delete the Finished slice, or recreate the cluster to recover. |
| `ElasticJobsViaWorkloadSlicesFlavorSplit` | `true` to let an elastic worker group overflow onto the next flavor, or leave the `false` default | Patch 0013 adds this gate ([contract](patches/kueue/contract.md#flavor-split-podsets)); it requires `ElasticJobsViaWorkloadSlicesFlavorChangeFromZero`. Only the split of a refused scale-up needs it: a Workload that already has split entries keeps them, carries them to its next slices and has their pods started, stopped and charged by entry after the gate is turned off, so turning it off strands no pod. Set `SCALEGATE_FLAVOR_SPLIT=true` on the KubeRay operator with it ([KubeRay Operator](#1-kuberay-operator)), so ScaleGate lets a worker group grow past one flavor; ScaleGate also sums the admitted entries of each worker group. |

`ElasticJobsViaWorkloadSlices` and `ReclaimablePods`, which partial preemption builds on, are on by default.

#### RayCluster webhook operations

Patch 0007 makes the RayCluster defaulting webhook re-stamp an elastic cluster's templates on every write, but the release manifests and the Helm chart register `mraycluster.kb.io` for `CREATE` only. Add `UPDATE` to its rule. The configuration's name depends on the install (the chart prefixes it with the release name), so look it up by the webhook it holds:

```bash
config=$(kubectl get mutatingwebhookconfiguration -o name | while read -r c; do
  kubectl get "$c" -o jsonpath='{.webhooks[*].name}' | grep -qw mraycluster.kb.io && echo "$c"
done)
index=$(kubectl get "$config" -o jsonpath='{.webhooks[*].name}' |
  awk '{for (i = 1; i <= NF; i++) if ($i == "mraycluster.kb.io") print i - 1}')
kubectl patch "$config" --type=json \
  -p '[{"op":"add","path":"/webhooks/'"$index"'/rules/0/operations/-","value":"UPDATE"}]'
```

A GitOps-managed Kueue reverts a `kubectl patch` at its next sync, and a Helm upgrade restores the chart's rule. In that case keep the change in version control instead: a kustomize patch that adds `UPDATE` to the `operations` of the `mraycluster.kb.io` rule, or a Helm post-renderer that does the same. Without it the patch has no effect, and a re-applied manifest drops the stamps as before.

Besides the PodSet label and the slice name, the job reconciler stamps other things on the templates when it starts a cluster, and a re-apply drops them too. Patch 0007 restores the topology scheduling gate and annotation, the Workload annotation, and the flavor placement, which matter here, and not these, which do not:

| Dropped stamp | Why it is harmless in this stack |
| :--- | :--- |
| Queue labels (`AssignQueueLabelsForPods`) | Only the labels for metrics and Pod selection; admission and ungating never read them. |
| MultiKueue worker label | Set only on copies that MultiKueue creates on a worker cluster, which no user manifest re-applies. |
| Admission-check selectors and annotations | The ungater adds them to each Pod, as it already does for ProvisioningRequests. |
| Admission-check tolerations and labels | Neither the Karpenter check nor the ProvisioningRequest check sets any (neither controller writes them to `podSetUpdates`). |

#### Rollback

Roll back only to the first p0.6.x release that contains `0008-redesign-rollback-compatibility.patch`. Earlier p0.6.x releases suspend every running Ray job this stack admitted, because they compare the `minCount` this stack does not set, and refuse to start when the configuration names `PartialPreemption`. To roll back:

1. On this stack, set `PartialPreemption` to `false`, so no new reclaim target is written.
2. Wait until no Workload carries a reclaim target: `kubectl get workloads -A -o json | jq '[.items[] | select(.metadata.annotations["kueue.x-k8s.io/reclaim-target-counts"] != null and ((.status.conditions // []) | any(.type == "Finished" and .status == "True") | not))] | length'` prints 0. Patch 0008 clears a target, with the `reclaimablePods` it set, once the Workload's quota is released, and a regrow slice starts without one; a shrunk cluster that keeps running keeps its target. Evict each one that remains, for example by setting its Workload's `spec.active` to `false` and back to `true`, which stops its job. The rollback release ignores the annotation: its ungater would ungate the workers KubeRay recreated, up to the admitted count, while `reclaimablePods` keeps their quota released, so the cluster would run over its quota.
3. Remove `UPDATE` from the `mraycluster.kb.io` rule, reversing the [webhook setup](#raycluster-webhook-operations). The rollback release leaves updates unchanged even if it stays, but nothing would use it.
4. Keep the gate list: `ConcurrentAdmission=true` and `ElasticJobsViaWorkloadSlicesWithPartialReplicaScaleUp=true` as before, `ElasticJobsViaWorkloadSlicesFlavorChangeFromZero` as you set it, and `PartialPreemption` either removed or `false`; the rollback release accepts the name and ignores it.
5. Deploy the rollback image.

Afterwards, a Ray Workload this stack created keeps matching its job while it holds quota; once its quota is released, Kueue rebuilds it with the rollback release's `minCount`. The rollback release's own behavior applies again, including the replica sync of its patch 0001. The rollback release names scale-up probes after the admitted level, so the probe-name gap described under [Feature Gates](#feature-gates) applies to chains reclaimed before the rollback as well.

#### Required RBAC for Karpenter JIT AdmissionCheck
When using the in-tree Karpenter AdmissionCheck controller for JIT gang pre-provisioning, grant Kueue permission to manage `karpenter.sh/v1` `NodeClaim` resources, read `NodePool`s, and patch `Node`s. The controller reads NodeClaim status but never writes it; it patches NodeClaims and Nodes only to remove the `karpenter.sh/do-not-disrupt` annotation it added. Kueue's own ClusterRole already lets it list the Pods on a Node:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kueue-karpenter-nodeclaims
rules:
  - apiGroups: ["karpenter.sh"]
    resources: ["nodeclaims"]
    verbs: ["get", "list", "create", "patch", "delete"]
  - apiGroups: ["karpenter.sh"]
    resources: ["nodepools"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kueue-karpenter-nodeclaims
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kueue-karpenter-nodeclaims
subjects:
  - kind: ServiceAccount
    name: kueue-controller-manager
    namespace: kueue-system
```

#### Configure Karpenter AdmissionCheck
Define the AdmissionCheck and run it only on the flavors Karpenter provisions, so that a flavor without it, such as a virtual-kubelet flavor for remote capacity, is where workloads go when Karpenter cannot launch nodes. List the Karpenter flavors first in the resource group, and name each flavor's NodePool in its `karpenter.sh/nodepool` node label:

```yaml
apiVersion: kueue.x-k8s.io/v1beta2
kind: AdmissionCheck
metadata:
  name: karpenter-provision
  annotations:
    kueue.x-k8s.io/karpenter-launch-timeout: 5m    # default 5m
    kueue.x-k8s.io/karpenter-wait-for: Launched    # Launched (default) or Registered
    kueue.x-k8s.io/karpenter-flavor-cooldown: 10m  # default 10m
    kueue.x-k8s.io/karpenter-node-fill-fraction: "0.5"  # default 0.5
    kueue.x-k8s.io/karpenter-max-nodeclaims: "100"      # default 100
    # Only for flavors that name no NodePool; there is no default.
    # kueue.x-k8s.io/karpenter-node-class: karpenter.k8s.aws/EC2NodeClass/default
spec:
  controllerName: kueue.x-k8s.io/karpenter
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ResourceFlavor
metadata:
  name: karpenter-gpu
spec:
  nodeLabels:
    karpenter.sh/nodepool: gpu   # an existing Karpenter NodePool
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: training
spec:
  admissionChecksStrategy:
    admissionChecks:
      - name: karpenter-provision
        onFlavors: [karpenter-gpu]
  resourceGroups:
    - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
      flavors:
        - name: karpenter-gpu   # nodeLabels become NodeClaim requirements
          resources: [...]
        - name: remote-gpu      # no Karpenter check
          resources: [...]
```

When a flavor names a NodePool, the check reads it and builds each NodeClaim the way Karpenter builds its own: the NodePool's `nodeClassRef`, requirements, taints, startup taints, `expireAfter`, `terminationGracePeriod`, and template labels and annotations, plus the `karpenter.sh/nodepool` label, the NodePool's hash annotations, and an owner reference to the NodePool. Each NodeClaim also requires the flavor's node labels and carries the `karpenter.sh/claimed-by` taint. The attempt fails, like one Karpenter cannot launch, when the NodePool does not exist, sets `spec.replicas` (Karpenter removes NodeClaims beyond a static NodePool's replicas), or would exceed its `spec.limits`: Karpenter checks limits only for NodeClaims it creates itself, so the check adds the NodeClaims' requests, and one node each, to the NodePool's `status.resources`. Instances usually have more than they are asked for, so this check can let usage pass a limit by the difference. A flavor that names no NodePool gets NodeClaims with the node class of the `karpenter-node-class` annotation, requiring `kubernetes.io/os=linux` plus the flavor's node labels; the check logs a warning for them, since Karpenter applies no NodePool limits, drift, or repair to them. Without the annotation, the attempt fails.

Each NodeClaim's `spec.resources.requests` are the effective requests of the pods it is sized for, as Kubernetes computes them from the pod template: containers, init containers, sidecars, and pod overhead, for `cpu`, `memory`, `ephemeral-storage`, `nvidia.com/gpu`, and any other extended resource. Karpenter launches only instance types whose allocatable resources cover them.

The check packs the pods of a pod set onto fewer NodeClaims when the NodePool's requirements bound the instance size. It reads the largest allowed value of `karpenter.k8s.aws/instance-cpu`, `karpenter.k8s.aws/instance-memory` (MiB), and `karpenter.k8s.aws/instance-gpu-count` from `In` and `Lt` requirements of the NodePool and the flavor, and puts `k` pods on each NodeClaim, where `k` is the largest number of pods whose requests fit in the `karpenter-node-fill-fraction` share of that instance, so it creates `ceil(count/k)` NodeClaims, the last one sized for the remaining pods. A pod set whose pods request a resource without one of these labels, such as `ephemeral-storage` or an extended resource other than `nvidia.com/gpu`, or whose NodePool leaves one of them unbounded, for example by listing instance types by name, gets one NodeClaim per pod. The fraction leaves room for the kubelet's reserved resources and DaemonSets, which the check does not count; lower it if packed NodeClaims fail to launch. An attempt that needs more NodeClaims than `karpenter-max-nodeclaims` fails before creating any, so the Workload moves to the next flavor.

NodeClaims in a NodePool carry `karpenter.sh/do-not-disrupt: "true"`, which Karpenter copies to the Node, so consolidation does not remove a launched node before its pods arrive. Once the check is Ready, it removes the annotation from each NodeClaim and its Node as soon as the Node runs as many pods, not counting DaemonSet pods, as the NodeClaim was sized for. A NodePool whose template already sets the annotation keeps it.

The check is Ready once every NodeClaim reports the `karpenter-wait-for` condition. It fails the attempt when a NodeClaim is deleted before that, which is how Karpenter reports insufficient capacity or a NodeClass that is not ready, or when the launch timeout passes since quota was reserved. It then deletes the NodeClaims, records the failed flavors in the Workload's `kueue.x-k8s.io/karpenter-excluded-flavors` annotation, sets `kueue.x-k8s.io/workload-allowed-resource-flavors` to the ClusterQueue's other flavors, and sets the check to Retry. Kueue evicts the Workload and assigns it the first allowed flavor that fits. The exclusions are removed when the Workload is admitted, so a later eviction tries the Karpenter flavor again, and each expires after the cooldown, so a Workload that fits nowhere else returns to the Karpenter flavor. The check leaves a Workload whose allowed flavors another controller set unchanged, and only retries it.

The check deletes a Workload's NodeClaims when the Workload finishes, is evicted, deactivated, or deleted, or loses its quota reservation, and when a new reservation replaces the one they were created for. Every 5 minutes the leader also deletes NodeClaims older than 2 minutes whose Workload is gone or no longer holds that reservation, which covers deletions missed while Kueue was down. NodeClaims created by earlier versions of this patch lack the `kueue.x-k8s.io/workload-namespace` and `kueue.x-k8s.io/karpenter-attempt` labels, so the sweep leaves them alone; delete them by hand once their Workloads are gone.

NodeClaims without a NodePool are still launched, registered, and terminated by Karpenter v1.15: deleting a NodeClaim drains and deletes its Node and terminates the instance, and `expireAfter` (720h by default) deletes it. Disruption skips nodes without a NodePool, so Karpenter never consolidates, drifts, or repairs them, and they count toward no NodePool limit.

---

### 3. interLink Virtual Kubelet

The patched image is a drop-in replacement for `ghcr.io/interlink-hq/interlink/virtual-kubelet-inttw:0.6.2`: it keeps the `/vk` entrypoint and runs as the distroless `nonroot` user (`65532`). Point the virtual kubelet container of your interLink deployment at it:

```yaml
containers:
  - name: virtual-kubelet
    image: ghcr.io/simonepri/interlink-virtual-kubelet:0.6.2-p0.1.0
```

---

## Quickstart & Local Testing

This repository uses [`mise`](https://mise.jdx.dev) to manage dependencies (`go`, `kind`, `kubectl`, `chainsaw`, `helm`, `ko`, `colima`, `docker-cli`).

```bash
# Clone the repository
git clone https://github.com/simonepri/elastic-kueue-kuberay-patches.git
cd elastic-kueue-kuberay-patches

# Install all development tools
mise install

# Clone upstream repos, apply patches, build OCI images, and spin up Kind cluster
mise run cluster:up

# Run the integration test scenarios that pass with the default Kueue gates
mise run test

# Run every scenario, partial preemption included, on a cluster with the gates of the second CI leg
mise run cluster:down
KUEUE_FEATURE_GATES=ConcurrentAdmission=true,ElasticJobsViaWorkloadSlicesWithPartialReplicaScaleUp=true,ElasticJobsViaWorkloadSlicesFlavorChangeFromZero=true,PartialPreemption=true,ElasticJobsViaWorkloadSlicesFlavorSplit=true mise run cluster:up
CHAINSAW_SELECTOR= mise run test

# Run the patched Kueue unit tests
mise run test:kueue

# Run the patched KubeRay unit tests
mise run test:kuberay

# Run the patched interLink virtual kubelet unit tests
mise run test:interlink

# Run the patched Ray unit tests inside a Ray image variant (default: the CPU image)
RAY_VARIANT=-gpu mise run test:ray

# Tear down the local Kind cluster
mise run cluster:down
```

---

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
