# Elastic Kueue & KubeRay Patches

[![CI](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/ci.yaml/badge.svg)](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/ci.yaml)
[![Release Please](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/release-please.yaml/badge.svg)](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/release-please.yaml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Tested on Kueue](https://img.shields.io/badge/tested%20on%20kueue-v0.20.2-blue)](https://github.com/kubernetes-sigs/kueue/releases/tag/v0.20.2)
[![Tested on KubeRay](https://img.shields.io/badge/tested%20on%20kuberay-v1.7.1-blue)](https://github.com/ray-project/kuberay/releases/tag/v1.7.1)
[![Tested on Karpenter](https://img.shields.io/badge/tested%20on%20karpenter-v1.15.0-blue)](https://github.com/kubernetes-sigs/karpenter/releases/tag/v1.15.0)
[![Tested on interLink](https://img.shields.io/badge/tested%20on%20interlink-0.6.2-blue)](https://github.com/interlink-hq/interLink/releases/tag/0.6.2)
[![Tested on Ray](https://img.shields.io/badge/tested%20on%20ray-2.59.0-blue)](https://github.com/ray-project/ray/releases/tag/ray-2.59.0)

Production patchsets for running elastic Ray clusters shared across teams on Kubernetes with [Kueue](https://github.com/kubernetes-sigs/kueue), [KubeRay](https://github.com/ray-project/kuberay), and [Karpenter](https://github.com/kubernetes-sigs/karpenter), plus a patched [interLink](https://github.com/interlink-hq/interLink) virtual kubelet for bursting Ray workers onto remote capacity and a patched [Ray](https://github.com/ray-project/ray) image whose head reaches those workers' agents through the gRPC proxy.

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
| **18** | `kubernetes-sigs/kueue` | [`0002-ray-min-count-migration.patch`](patches/kueue/0002-ray-min-count-migration.patch) | Patch releases up to p0.6.x set `minCount` to `minReplicas` on every worker group of a RayCluster, RayJob, or RayService Workload, and KubeRay defaults `minReplicas` to 0. Kueue compares `minCount` when it checks that a job still matches its Workload, so after an upgrade every running Ray job those releases admitted stops matching: Kueue deletes its Workload and suspends the job. Temporary, for the upgrade only. | The Ray integrations ignore `minCount` in that check while the Workload holds quota, through their `CustomEquivalenceOptions` and a new `WithIgnoreMinCount` comparison option. `minCount` only decides how many pods a Workload may be admitted with, so it cannot change what a Workload holding quota runs; once the quota is released, Kueue replaces the Workload's PodSets with the job's as usual, which drops the old `minCount`. Delete the patch once no Workload that held quota under p0.6.x or earlier remains ([migration](patches/kueue/contract.md#migration-from-p06x)). | `TestMinCountMigrationEquivalence` and `TestMinCountMigrationKeepsRunningCluster` in `pkg/controller/jobs/raycluster/min_count_migration_test.go`, and `TestMinCountMigrationSliceChain` in `pkg/controller/jobframework/min_count_migration_test.go` (added by the patch; `mise run test:kueue`) |
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
| **13** | `kubernetes-sigs/kueue` | [`0005-topology-aware-reclaim.patch`](patches/kueue/0005-topology-aware-reclaim.patch) | Preemption takes victims lowest priority first and stops once each borrowing ClusterQueue is back at its nominal quota. When those victims sit in different topology domains, the freed capacity is scattered, the plan fails the TAS check, and nothing is preempted: a workload that needs a whole node or rack stays pending even though freeing one domain was allowed. Applies to Classic and Fair Sharing preemption. Upstream: [issue #10815](https://github.com/kubernetes-sigs/kueue/issues/10815), [draft PR #17834](https://github.com/kubernetes-sigs/kueue/pull/17834). | When ordinary preemption frees enough quota but no topology placement, and fails at every pod count partial admission tries, retries once at the full count. The retry raises a priority ceiling through the candidates' priorities and starts at the first one, found by bisection, where removing every candidate at or below it frees the quota and a placement; removing more never frees less, so no victim set with a lower highest-priority victim exists, however many domains there are. It checks which candidates the strategies may take by removing their quota from the snapshot and asking Kueue's own resource tree whether each ClusterQueue and Cohort below the shared Cohort still borrows, so guaranteed quota, lending limits, and nested Cohorts count exactly as the strategies count them. At that ceiling each topology leaf offers the occupants its lenders may give up together, chosen from the most expensive down; the retry frees the cheapest leaves first, and when the strategy's cheapest-first order would use up a lender before an occupant the placement needs, keeps only the occupants the placement needs. It runs the preemption strategy with each placement's victims ahead of priority for up to 8 placements, skipping without an evaluation those whose victims the lenders may not give up in any order, and keeps the victims that cost the least. Every preemption policy still applies, and each attempt runs at most 64 + 8 x (2 x bits(L) + 8) topology searches for L topology leaves (304 at 1024 nodes). Exact: no legal victim set has a lower highest-priority victim than one the retry returns at its starting ceiling, assuming freeing capacity never stops a placement from fitting. Best effort: the lowest next-highest victims and the fewest victims compare only the placements found in greedy leaf order, and a placement whose trimmed victims the lenders reject is skipped even if another subset would pass. A retry that finds no victims is not repeated for the same workload until its effective priority or an admission, eviction, quota, policy, or topology change in its cohort or topology flavors changes; admission fair sharing, configurable preemptions, and the scheduler library integration turn this memory off. Elastic victims are evicted whole, like any other workload; patch 0010 will let the retry shrink them ([contract](patches/kueue/contract.md)). Known limitation: the retry runs only at the full count, so a reduced count that only the topology blocks is not retried. | `TestPreemptionReclaimsTopologyDomain` in `pkg/scheduler/preemption/preemption_tas_test.go`, `TestTopologyRetryComparesEveryDomain`, `TestTopologyRetryWithDistinctPriorities`, `TestTopologyRetryRemembersFailures`, and `TestTopologyRetryForgetsFailuresAfterPriorityBoost` in `pkg/scheduler/preemption/topology_retry_test.go`, `TestTopologyRetryRespectsReclaimLimits` and `TestTopologyRetryMatchesStrategyLimits` in `pkg/scheduler/preemption/topology_retry_limits_test.go`, `TestTopologyRetryWithPartialAdmission` in `pkg/scheduler/scheduler_tas_topology_retry_test.go`, and the `Topology-aware cohort reclaim` suite in `test/integration/singlecluster/tas/tas_preemption_topology_test.go` (added by the patch; `mise run test:kueue` and `mise run test:kueue-integration`) |

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

Scenarios 05, 09, and 12 are skipped until the partial preemption patches return; each `chainsaw-test.yaml` names the patch that runs it again, and [the contract](patches/kueue/contract.md#acceptance-tests) lists what it must then assert. Scenario 12 holds the steps of scenario 10 that need partial preemption or re-expansion, so 10's spot interruption steps still run; 09 stays skipped whole, because its cohort reclaim step needs the redesign and its ScaleGate step cannot run without it; `kuberay/03-scalegate-quota/03-borrowing-limit-clamping` covers that clamp.

---

## Dual Versioning Scheme

Images published by this repository use a compound tag format:

$$\text{Image Tag} = \langle\text{upstream-version}\rangle\text{-p}\langle\text{patch-version}\rangle$$

Examples:
- `ghcr.io/simonepri/kueue:v0.20.2-p0.2.0`
- `ghcr.io/simonepri/kuberay-operator:v1.7.1-p0.2.0`
- `ghcr.io/simonepri/interlink-virtual-kubelet:0.6.2-p0.1.0`
- `ghcr.io/simonepri/ray:2.59.0-py313-p0.1.0` (the upstream image tag, including its Python suffix, then the patch version)

The Ray patch is published on top of each upstream Ray image listed in [`patches/ray/variants.json`](patches/ray/variants.json), with the same platforms:

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
| `ElasticJobsViaWorkloadSlicesWithPartialReplicaScaleUp` | `true` | Patch releases up to p0.6.x turned it on in code and gave elastic Workloads a `minCount`. Without the gate, the Workload webhook rejects every update to such a Workload, status updates included. Clusters with the `kueue.x-k8s.io/elastic-job-scale-up-strategy: partial` annotation need it permanently, for partial scale-up. Turn it off only when no job carries that annotation and `kubectl get workloads -A -o json \| jq '[.items[] \| select(.metadata.annotations["kueue.x-k8s.io/elastic-job"] == "true" and any(.spec.podSets[]; .minCount != null))] \| length'` prints 0; an elastic cluster drops the old `minCount` at its next scale-up, since an in-place scale-down keeps it, or when it is recreated ([migration](patches/kueue/contract.md#migration-from-p06x)). |
| `ElasticJobsViaWorkloadSlicesFlavorChangeFromZero` | `false` (default) | Patch release p0.6.1 turned it on in code. Turn it on together with patch 0006, which puts the new flavor's node labels and tolerations on the pods of a moved PodSet; until then those pods would not run where Kueue counted them. |
| `PartialPreemption` | leave unset | Patch 0008 adds this gate ([contract](patches/kueue/contract.md#feature-gate)); Kueue refuses to start with a gate name it does not know. Turn it on only after the partial preemption scenarios with Ray autoscaling enabled pass. |

`ElasticJobsViaWorkloadSlices` and `ReclaimablePods`, which partial preemption builds on, are on by default.

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

# Run all integration test scenarios across Kueue and KubeRay
mise run test

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
