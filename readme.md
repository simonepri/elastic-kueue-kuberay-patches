# elastic-kueue-kuberay-patches

[![license](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](license)
[![kubernetes](https://img.shields.io/badge/kubernetes-1.36+-326CE5.svg)](https://kubernetes.io/)
[![chainsaw tests](https://img.shields.io/badge/chainsaw-9%20passed-brightgreen.svg)](tests/)
[![renovate](https://img.shields.io/badge/renovate-enabled-326CE5.svg)](renovate.json)

An open-source patch distribution and automated OCI build pipeline providing upstream-native elastic GPU autoscaling, fractional preemption, and anti-theft node reservation across **Kueue**, **KubeRay**, and **Karpenter**.

Rather than running an external coordinator or proprietary orchestrator, this repository redistributes clean, tested patches that compile directly into standard upstream controller binaries and drop-in OCI images.

---

## Dual-Version Scheme (Upstream + Patchset)

To make both the upstream component version and our internal patch iterations easily trackable, container images and Git releases follow a two-tier versioning format:

$$\text{Tag} = \mathbf{\langle\text{upstream}\rangle}\text{-p}\mathbf{\langle\text{patchset}\rangle}$$

For example:
* **Kueue**: `ghcr.io/simonepri/elastic-kueue-kuberay-patches/kueue:v0.10.1-p0.1.0`
  *(Built on upstream Kueue `v0.10.1` with patchset revision `0.1.0`)*
* **KubeRay**: `ghcr.io/simonepri/elastic-kueue-kuberay-patches/kuberay-operator:v1.2.2-p0.1.0`
  *(Built on upstream KubeRay `v1.2.2` with patchset revision `0.1.0`)*

If we refine or bugfix a patch without changing the upstream base version, only the patchset component bumps (e.g. `v0.10.1-p0.2.0`). When Renovate detects a new upstream release (e.g. `v0.10.2`), the upstream base bumps independently (e.g. `v0.10.2-p0.1.0`).

---

## Architecture & Upstream Patches

All extensions use official Kubernetes and ecosystem label/taint namespaces (`kueue.x-k8s.io/*`, `karpenter.sh/*`, `kuberay.io/*`).

```
 +-------------------------------------------------------------------------------+
 |                            Kubernetes v1.36+ Cluster                          |
 |                                                                               |
 |   +------------------------------------+   +-------------------------------+  |
 |   |          sigs.k8s.io/kueue         |   |      ray-project/kuberay      |  |
 |   |         (Patched In-Tree)          |   |       (Patched In-Tree)       |  |
 |   |                                    |   |                               |  |
 |   |  - Fractional Partial Preemption   |   |  - Actor State Deletion Cost  |  |
 |   |  - Karpenter JIT AdmissionCheck    |   |  - Spot Notice Contraction    |  |
 |   |  - Anti-Theft Node Reservation     |   |  - Quota Scale-Gate Clamping  |  |
 |   +-----------------+------------------+   +---------------+---------------+  |
 |                     |                                      |                  |
 |                     v                                      v                  |
 |       karpenter.sh/v1 NodeClaims              RayCluster Spec Synchronization |
 +-------------------------------------------------------------------------------+
```

### 1. `patches/kueue/`
* **`0001-partial-preemption.patch`**: Extends Kueue's preemption algorithm from all-or-nothing cluster eviction to fractional, workload-aware downsizing. Reclaims surplus capacity (or borrowed cohort quota) without terminating head pods or distributed actor state.
* **`0002-karpenter-admission-check.patch`**: Native `kueue.x-k8s.io/karpenter` AdmissionCheck controller. Provisions just-in-time `karpenter.sh/v1` `NodeClaim` resources for pending gang workloads and injects `karpenter.sh/claimed-by` anti-theft taints so competing rogue pods cannot steal newly provisioned GPU capacity.

### 2. `patches/kuberay/`
* **`0001-actor-protect-spot-interruption-scalegate.patch`**:
  * **Actor Protection**: Inspects `ray.io/actor-state` and injects `controller.kubernetes.io/pod-deletion-cost: 1000` on busy pods and `-1000` on idle workers so Kubernetes downscaling drains only idle pods.
  * **Spot Interruption**: Intercepts spot termination notices, dynamically contracts `workerGroupSpecs.replicas` and `maxReplicas`, and targets the interrupted pod via `scaleStrategy.workersToDelete` before abrupt termination.
  * **Scale-Gate**: Clamps autoscaler expansion to Kueue ClusterQueue nominal and cohort borrowing limits, eliminating pending pod churn.

---

## Validated Scenarios (Kyverno Chainsaw Suite)

Every pattern is verified on Kind using declarative Kyverno Chainsaw assertions:

| Scenario | Objective | Stock Failure Mode | Patched Resolution | Status |
| :--- | :--- | :--- | :--- | :--- |
| **01-cold-start-gang** | 4-GPU gang training job with 0 initial nodes. | **Deadlock**: Kueue holds Job in `suspend: true`; Karpenter waits for unsuspended pods. | Karpenter AdmissionCheck creates JIT NodeClaims and approves check once ready. | **PASS** |
| **02-elastic-scaleup-quota** | RayCluster worker group scales from 2 to 8 replicas with 4-GPU quota. | **Quota Blindness**: Ray autoscaler creates pending pods blocked in Kueue indefinitely. | ScaleGate clamps `maxReplicas` and `replicas` to available quota. | **PASS** |
| **03-collaborative-preemption** | High-priority 2-GPU job arrives while RayCluster holds 8 GPUs. | **Destructive Preemption**: Kueue terminates whole RayCluster, destroying in-memory state. | Kueue calculates exact deficit and drains 2 workers; head pod and state survive. | **PASS** |
| **04-spot-interruption** | Ray worker node receives 2-min spot notice. | **Abrupt Eviction**: Worker deleted mid-computation without draining actors. | Operator intercepts event, contracts `maxReplicas`, and targets worker for clean drain. | **PASS** |
| **05-anti-theft-reservation** | Specialized GPU node claimed for gang workload arrives. | **Capacity Theft**: Opportunistic pods land on the node before the gang pods initialize. | NodeClaim is provisioned with anti-theft taints; rogue pods rejected; target gang admitted. | **PASS** |
| **06-elastic-reexpansion** | Preemptor completes and exits, releasing 2 GPUs. | **Permanent Downscale**: RayCluster stays clamped at 6 workers forever even when quota is idle. | Workload controller restores RayCluster back to full capacity when quota frees. | **PASS** |
| **07-min-viable-replicas** | Preemptor requests 6 of 8 GPUs, but RayCluster has `minReplicas: 4`. | **Gang Inoperability**: Shrinking to 2 workers destroys tensor parallelism. | Kueue detects threshold breach and safely refuses partial drain. | **PASS** |
| **08-actor-aware-drain** | Worker downscale occurs while some pods run active stateful actors. | **State Destruction**: Kubernetes terminates pods arbitrarily, killing active actors. | Operator assigns `pod-deletion-cost: 1000` to busy pods and `-1000` to idle pods. | **PASS** |
| **09-cohort-borrowing-reclaim** | Team A borrows 2 GPUs from Team B; Team B arrives requiring its 4 nominal GPUs. | **Uncontrolled Eviction**: Arbitrary workloads evicted across queues. | Kueue identifies borrowed quota and reclaims only the 2 borrowed GPUs. | **PASS** |

---

## Quickstart & Local Verification

### Prerequisites
- [mise](https://mise.jdx.dev/) (manages `kind`, `kubectl`, `ko`, `chainsaw`, `helm`)
- Colima or Docker runtime

### Commands
```bash
# 1. Install toolchain via mise
mise install

# 2. Spin up Kind cluster with patched controllers built and deployed
mise run cluster:up

# 3. Run the full 9-scenario Chainsaw test suite
mise run test

# 4. Tear down cluster when done
mise run cluster:down
```

---


---

## Upstream Fix Detection & Patch Retirement

A primary goal of maintaining patches is retiring them as soon as upstream incorporates the fixes. 

To verify whether upstream has resolved any issue natively:

```bash
# 1. Switch cluster to stock unpatched upstream releases
mise run cluster:stock

# 2. Run the test suite against stock upstream
mise run test
```

* **Expected Outcome while patches are needed**: Tests fail with stock failure modes (e.g., Scenario 01 fails on missing `NodeClaim`, Scenario 03 terminates the cluster head pod, Scenario 08 fails without `pod-deletion-cost`).
* **Canary Signal for Patch Retirement**: If a scenario test **passes** against `cluster:stock`, **upstream has implemented the capability natively**. You can safely delete that patch from `patches/` and bump the patchset version!

## Maintenance & CI/CD Automation

- **Renovate (`renovate.json`)**: Watches upstream releases for `kubernetes-sigs/kueue`, `ray-project/kuberay`, and `kubernetes-sigs/karpenter`. When new versions appear, Renovate rebases patches and auto-merges PRs once CI checks pass.
- **Release Please (`release-please-config.json`)**: Independent semantic versioning per component (`kueue` and `kuberay`) to release new patchset versions whenever `patches/` change.
- **CI Workflow (`.github/workflows/ci.yaml`)**:
  1. Validates that all patches apply cleanly against target upstream releases (`git apply --check`).
  2. Creates a Kind cluster and installs base CRDs.
  3. Builds patched OCI images with `ko`.
  4. Executes the full 9-scenario Chainsaw integration test suite.
