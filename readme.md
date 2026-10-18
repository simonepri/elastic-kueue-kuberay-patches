# elastic-kueue-kuberay-patches

[![license](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](license)
[![kubernetes](https://img.shields.io/badge/kubernetes-1.32+-326CE5.svg)](https://kubernetes.io/)
<!-- renovate: datasource=github-releases depName=kubernetes-sigs/kueue -->
[![kueue](https://img.shields.io/badge/kueue-v0.10.1-326CE5.svg)](https://github.com/kubernetes-sigs/kueue/releases/tag/v0.10.1)
<!-- renovate: datasource=github-releases depName=ray-project/kuberay -->
[![kuberay](https://img.shields.io/badge/kuberay-v1.2.2-028CF0.svg)](https://github.com/ray-project/kuberay/releases/tag/v1.2.2)
<!-- renovate: datasource=github-releases depName=kubernetes-sigs/karpenter -->
[![karpenter](https://img.shields.io/badge/karpenter-v1.2.1-FF9900.svg)](https://github.com/kubernetes-sigs/karpenter/releases/tag/v1.2.1)
[![chainsaw tests](https://img.shields.io/badge/chainsaw-9%20passed-brightgreen.svg)](tests/)
[![renovate](https://img.shields.io/badge/renovate-enabled-326CE5.svg)](renovate.json)

Tested, drop-in patches and prebuilt container images for upstream **Kueue** and **KubeRay**, enabling collaborative elastic GPU autoscaling, fractional preemption, and anti-theft node reservation on **Karpenter**.

---

## 1. Upstream Architecture & Impedance Mismatches

When running distributed Ray workloads alongside Kueue and Karpenter, three independent control loops operate without coordination:

```
+---------------------------------------------------------------------------------------+
|                               STOCK UPSTREAM ARCHITECTURE                             |
|                                                                                       |
|   +--------------------------+                         +--------------------------+   |
|   |  Kueue Controller Mgr    |                         |     KubeRay Operator     |   |
|   +--------------------------+                         +--------------------------+   |
|   | • Monolithic Preemption  |                         | • Queue-Driven Scale-Up  |   |
|   |   (kills entire cluster  |                         |   (blind to Kueue quota; |   |
|   |    to reclaim 1 GPU)     |                         |    endless pending pods) |   |
|   | • Holds Jobs in Suspend  |                         | • Unaware of Spot Notice |   |
|   |   (Karpenter never sees  |                         |   (brutal worker death   |   |
|   |    pending pods)         |                         |    mid-computation)      |   |
|   +------------+-------------+                         +------------+-------------+   |
|                |                                                    |                 |
|                |  [1. Permanent Cold-Start Deadlock]                |                 |
|                |  Kueue waits for nodes before unsuspending;        |                 |
|                |  Karpenter waits for unsuspended pods.             |                 |
|                v                                                    v                 |
|   +-------------------------------------------------------------------------------+   |
|   |                              Karpenter Controller                             |   |
|   +-------------------------------------------------------------------------------+   |
|   | • Spins up specialized GPU nodes on demand                                    |   |
|   | • [Capacity Theft]: Non-gang opportunistic pods bind to newly provisioned     |   |
|   |   GPU nodes before the gang workload initializes.                             |   |
|   +-------------------------------------------------------------------------------+   |
+---------------------------------------------------------------------------------------+
```

---

## 2. Patched Architecture: Cooperative Elastic Scaling

The patches introduce in-tree synchronization across controllers using standard Kubernetes APIs and namespaces:

```
+---------------------------------------------------------------------------------------+
|                                  PATCHED ARCHITECTURE                                 |
|                                                                                       |
|   +---------------------------------------+   +-----------------------------------+   |
|   |  sigs.k8s.io/kueue (Patched)          |   |  ray-project/kuberay (Patched)    |   |
|   +---------------------------------------+   +-----------------------------------+   |
|   | • karpenter-provision AdmissionCheck: |   | • Quota Clamping:                 |   |
|   |   Directly mints karpenter.sh/v1      |   |   Reads ClusterQueue limits; sets |   |
|   |   NodeClaims for pending gangs.       |   |   hard ceiling on maxReplicas.    |   |
|   | • Anti-Theft Taint Injection:         |   | • Spot Notice Interception:       |   |
|   |   Injects karpenter.sh/claimed-by     |   |   Contracts replicas & designates |   |
|   |   taint to protect gang nodes.        |   |   target in workersToDelete.      |   |
|   | • Fractional Preemption:              |   | • Actor Protection:               |   |
|   |   Contracts Ray worker groups without |   |   Injects pod-deletion-cost for   |   |
|   |   killing head pod or actor state.    |   |   actor-aware downsizing.         |   |
|   +-------------------+-------------------+   +-----------------+-----------------+   |
|                       |                                         |                     |
|                       v                                         v                     |
|          karpenter.sh/v1 NodeClaims             controller.kubernetes.io/             |
|          (with Anti-Theft Taints)                  pod-deletion-cost                  |
|                       |                                         |                     |
|                       +--------------------+--------------------+                     |
|                                            |                                          |
|                                            v                                          |
|                           +---------------------------------+                         |
|                           |      Karpenter Controller       |                         |
|                           |   (Unmodified Stock Upstream)   |                         |
|                           +---------------------------------+                         |
+---------------------------------------------------------------------------------------+
```

---

## 3. Issues, Failure Modes, and Verified Fixes

Every scenario is tested in CI against a live Kubernetes cluster using [Kyverno Chainsaw](https://kyverno.github.io/chainsaw/):

| Scenario | Issue / Impedance Mismatch | Stock Failure Mode | Patched In-Tree Resolution | Test Code | Patch Source |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **01** | **Cold-Start Gang Deadlock** | Kueue holds gang Job in `suspend: true`; Karpenter waits for unsuspended pods → **Infinite Deadlock**. | Kueue AdmissionCheck controller mints `karpenter.sh/v1 NodeClaim` directly and marks check ready when nodes initialize. | [`01-cold-start-gang`](tests/scenarios/01-cold-start-gang/) | [`patches/kueue/0002-...`](patches/kueue/0002-karpenter-admission-check.patch) |
| **02** | **Autoscaler Quota Blindness** | KubeRay autoscaler scales `replicas` based on queue depth without knowing Kueue quota, creating endless pending pods. | KubeRay Operator inspects `ClusterQueue` quota and clamps `maxReplicas` and `replicas` to the available ceiling. | [`02-elastic-scaleup-quota`](tests/scenarios/02-elastic-scaleup-quota/) | [`patches/kuberay/0001-...`](patches/kuberay/0001-actor-protect-spot-interruption-scalegate.patch) |
| **03** | **Destructive Preemption** | Kueue terminates the entire RayCluster (killing head pod and actor memory) to reclaim even a single GPU. | Kueue calculates exact deficit, leaves head pod intact, and requests voluntary worker group contraction. | [`03-collaborative-preemption`](tests/scenarios/03-collaborative-preemption/) | [`patches/kueue/0001-...`](patches/kueue/0001-partial-preemption.patch) |
| **04** | **Uncoordinated Spot Eviction** | Cloud spot termination notice causes immediate ungraceful SIGKILL of worker pods mid-training step. | KubeRay Operator intercepts spot notice, dynamically contracts `maxReplicas`, and adds target pod to `workersToDelete`. | [`04-spot-interruption`](tests/scenarios/04-spot-interruption/) | [`patches/kuberay/0001-...`](patches/kuberay/0001-actor-protect-spot-interruption-scalegate.patch) |
| **05** | **Capacity Theft (Gang Hijack)** | Opportunistic non-gang pods schedule onto a specialized GPU node before the gang pods initialize. | Kueue provisions `NodeClaim` with `karpenter.sh/claimed-by` taint; rogue pods are rejected; target gang binds cleanly. | [`05-anti-theft-reservation`](tests/scenarios/05-anti-theft-reservation/) | [`patches/kueue/0002-...`](patches/kueue/0002-karpenter-admission-check.patch) |
| **06** | **Permanent Downscale Stagnation** | When a high-priority preemptor exits, RayCluster remains clamped at reduced replicas forever even when quota is free. | Kueue Workload controller monitors preemptor lifecycle and automatically signals RayCluster to re-expand. | [`06-elastic-reexpansion`](tests/scenarios/06-elastic-reexpansion/) | [`patches/kueue/0001-...`](patches/kueue/0001-partial-preemption.patch) |
| **07** | **Min-Viable Replicas Violation** | Preemption drains worker pods below distributed training tensor-parallelism threshold (`minReplicas`), breaking the job. | Kueue detects that required reclaim breaches `minReplicas`, refuses partial preemption, and emits status condition. | [`07-min-viable-replicas`](tests/scenarios/07-min-viable-replicas/) | [`patches/kueue/0001-...`](patches/kueue/0001-partial-preemption.patch) |
| **08** | **Arbitrary Worker Eviction** | Kubernetes downscales worker pods arbitrarily, killing active actors while idle pods survive. | KubeRay Operator annotates busy pods with `pod-deletion-cost: 1000` and idle pods with `-1000` for safe eviction. | [`08-actor-aware-drain`](tests/scenarios/08-actor-aware-drain/) | [`patches/kuberay/0001-...`](patches/kuberay/0001-actor-protect-spot-interruption-scalegate.patch) |
| **09** | **Cohort Borrowing Blindness** | Kueue terminates workloads unpredictably across queues when reclaiming borrowed cohort capacity. | Kueue tracks borrowed quota per cohort and reclaims only the exact borrowed capacity, admitting the rightful owner. | [`09-cohort-borrowing-reclaim`](tests/scenarios/09-cohort-borrowing-reclaim/) | [`patches/kueue/0001-...`](patches/kueue/0001-partial-preemption.patch) |

---

## 4. Prebuilt Container Images & Versioning

Images follow a two-tier versioning format tracking the upstream release and internal patchset revision:

$$\\text{Tag} = \\mathbf{\\langle\\text{upstream}\\rangle}\\text{-p}\\mathbf{\\langle\\text{patchset}\\rangle}$$

| Component | Image | Upstream Base |
| :--- | :--- | :--- |
| **Kueue** | `ghcr.io/simonepri/elastic-kueue-kuberay-patches/kueue:v0.10.1-p0.1.0` | [`kubernetes-sigs/kueue v0.10.1`](https://github.com/kubernetes-sigs/kueue/releases/tag/v0.10.1) |
| **KubeRay Operator** | `ghcr.io/simonepri/elastic-kueue-kuberay-patches/kuberay-operator:v1.2.2-p0.1.0` | [`ray-project/kuberay v1.2.2`](https://github.com/ray-project/kuberay/releases/tag/v1.2.2) |

---

## 5. Quickstart & Local Verification

### Prerequisites
- [mise](https://mise.jdx.dev/) *(automatically provisions `go`, `kind`, `kubectl`, `helm`, `ko`, `chainsaw`, `colima`, and `docker-cli`)*

### Commands
```bash
# 1. Install toolchain via mise
mise install

# 2. Spin up local Kind cluster with patched controllers deployed
mise run cluster:up

# 3. Execute the full 9-scenario Chainsaw test suite
mise run test

# 4. Tear down cluster when done
mise run cluster:down
```

---

## 6. Upstream Canary & Patch Retirement

To test for patch retirement when upstream projects release new versions:

```bash
# Deploy official stock unpatched upstream releases
mise run cluster:stock

# Run the test suite against stock upstream
mise run test
```

* **Expected while patches are required**: Tests fail with stock failure modes (e.g. Scenario 01 fails on missing `NodeClaim`; Scenario 03 terminates the cluster head pod).
* **Canary Signal**: If a scenario **passes** against `cluster:stock`, upstream has natively resolved the issue. The corresponding patch can be retired from `patches/`.
