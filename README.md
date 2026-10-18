# Kyield: Collaborative Elastic Autoscaling & Preemption for Kubernetes

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.36+-326CE5.svg)](https://kubernetes.io/)
[![Chainsaw Tests](https://img.shields.io/badge/Chainsaw-9%20passed-brightgreen.svg)](tests/)

**Kyield** (*"k-yield"*) is a non-invasive, thinning-out collaborative capacity coordinator for Kubernetes. It bridges the impedance mismatches between **Karpenter v1.2+**, **Kueue v0.10+**, **KubeRay v1.2+**, and **DRA** without requiring forks or patches to upstream projects.

---

## 1. Why Kyield?

When running distributed Ray and batch ML training alongside dynamic cloud autoscalers, three distinct control loops collide:
1. **Kueue** controls admissions and quota, but its preemption is monolithic: it terminates entire clusters (killing head pods, distributed actor state, and in-memory caches) to reclaim even a single GPU.
2. **KubeRay Autoscaler** scales workers up and down based on task queue depth, but is completely blind to Kueue quota boundaries and cohort borrowing limits.
3. **Karpenter** provisions just-in-time GPU nodes based on pending pods, but Kueue suspends batch jobs until quota is satisfied, creating a cold-start gang deadlock.

**Kyield solves this by teaching distributed clusters to *yield* capacity cooperatively instead of dying.**

---

## 2. Test Scenarios (Kyverno Chainsaw Suite)

Every scenario is tested against a live Kubernetes v1.36+ cluster using declarative Kyverno Chainsaw assertions:

| Scenario | Objective | Stock Failure Mode | Kyield Solution | Status |
| :--- | :--- | :--- | :--- | :--- |
| **01-cold-start-gang** | 4-GPU gang training job with 0 initial nodes. | **Deadlock**: Kueue holds Job in `suspend: true`; Karpenter waits for unsuspended pods. | `Preprovisioner` handles `AdmissionCheck`, mints JIT `NodeClaim`, marks check `Ready`. | **PASS** |
| **02-elastic-scaleup-quota** | RayCluster worker group scales from 2 to 8 replicas with 4-GPU quota. | **Quota Blindness**: Ray autoscaler creates pending pods blocked in Kueue indefinitely. | `ScaleGate` clamps `maxReplicas` and `replicas` to 4. | **PASS** |
| **03-collaborative-preemption** | High-priority 2-GPU job arrives while RayCluster holds 8 GPUs. | **Destructive Preemption**: Kueue terminates whole RayCluster, destroying in-memory state. | `Preemption` calculates deficit, voluntarily drains 2 workers; head pod survives. | **PASS** |
| **04-spot-interruption** | Ray worker node receives 2-min spot notice. | **Abrupt Eviction**: Worker deleted mid-computation without draining actors. | `SpotInterruption` intercepts notice, contracts `maxReplicas`, targets `workersToDelete`. | **PASS** |
| **05-anti-theft-reservation** | Specialized GPU node claimed for gang workload arrives. | **Capacity Theft**: Random opportunistic pods land on the node before the gang pods initialize. | NodeClaim is provisioned with anti-theft taints; rogue pods rejected; target gang tolerated. | **PASS** |
| **06-elastic-reexpansion** | Preemptor completes and exits, releasing 2 GPUs. | **Permanent Downscale**: RayCluster stays clamped at 6 workers forever even when quota is idle. | Coordinator monitors preemptor lifecycle and automatically restores RayCluster back to 8 replicas. | **PASS** |
| **07-min-viable-replicas** | Preemptor requests 6 of 8 GPUs, but RayCluster has `minReplicas: 4`. | **Gang Inoperability**: Shrinking to 2 workers destroys tensor-parallelism / distributed pipeline. | Coordinator detects threshold breach, safely refuses partial drain, and publishes `PartialPreemptionRefused: True`. | **PASS** |
| **08-actor-aware-drain** | Worker downscale occurs while some pods run active stateful actors. | **State Destruction**: Kubernetes terminates pods arbitrarily, killing active actors or shuffle cache. | `ActorProtect` assigns `pod-deletion-cost: 1000` to busy pods and `-1000` to idle pods. | **PASS** |
| **09-cohort-borrowing-reclaim** | Team A borrows 2 GPUs from Team B; Team B arrives requiring its 4 nominal GPUs. | **Uncontrolled Eviction**: Kueue evicts arbitrary workloads across queues. | Coordinator identifies borrowed quota, reclaims only the 2 borrowed GPUs, and admits Team B. | **PASS** |

---

## 3. Quickstart

### Prerequisites
- [mise](https://mise.jdx.dev/) (or Go 1.24+, Kind, Kubectl, Chainsaw)
- Colima or Docker runtime

### Commands
```bash
# 1. Install toolchain
mise install

# 2. Build production binary (bin/kyield) and test fixture (bin/test-nodesim)
make build

# 3. Create Kind cluster and install CRDs
make kind-up
make install-crds

# 4. Run full 9-scenario Chainsaw test suite
make test
```

---

## 4. Upstream Retirement Roadmap & Issue Traceability

Kyield is explicitly architected as a temporary "thinning-out" shim that evaporates into upstream projects as the following KEPs, issues, and PRs graduate:

| Kyield Component | Upstream Project | Tracking Issues & KEPs | Retirement Condition |
| :--- | :--- | :--- | :--- |
| **`pkg/preprovisioner`** | **Kueue** & **Karpenter** | • [kubernetes-sigs/kueue#5133](https://github.com/kubernetes-sigs/kueue/issues/5133) (Kueue & Karpenter Support)<br/>• [kubernetes-sigs/kueue#3419](https://github.com/kubernetes-sigs/kueue/issues/3419) (ProvisioningRequest v1 API)<br/>• [kubernetes-sigs/kueue#3249](https://github.com/kubernetes-sigs/kueue/issues/3249) (External AdmissionCheck Controller)<br/>• [kubernetes-sigs/kueue#17156](https://github.com/kubernetes-sigs/kueue/issues/17156) (Admit when provisioned nodes are usable)<br/>• [kubernetes-sigs/karpenter#4878](https://github.com/kubernetes-sigs/karpenter/issues/4878) (Capacity Reservation / ProvisioningRequest) | Native Karpenter driver for Kueue `ProvisioningRequest` or dynamic DRA capacity check graduates. |
| **`pkg/scalegate`** | **KubeRay** & **Kueue** | • [ray-project/kuberay#1850](https://github.com/ray-project/kuberay/issues/1850) (Kueue gang scheduling & quota management)<br/>• [ray-project/kuberay#5233](https://github.com/ray-project/kuberay/issues/5233) (ScaleGate signal on RayCluster for quota limits)<br/>• [kubernetes-sigs/kueue#7569](https://github.com/kubernetes-sigs/kueue/issues/7569) (Ray autoscaler vs Kueue admission model) | KubeRay implements native Kueue Elastic Workload protocol clamping autoscaler within nominal quota. |
| **`pkg/preemption`** | **Kueue** | • [kubernetes-sigs/kueue#975](https://github.com/kubernetes-sigs/kueue/issues/975) (Partial preemption of workloads & RayCluster)<br/>• [kubernetes-sigs/kueue#8651](https://github.com/kubernetes-sigs/kueue/issues/8651) (ElasticJobsViaWorkloadSlices for Ray)<br/>• [kubernetes-sigs/kueue#9891](https://github.com/kubernetes-sigs/kueue/issues/9891) (Automatic scale-up/re-expansion for elastic jobs)<br/>• [kubernetes-sigs/kueue#10167](https://github.com/kubernetes-sigs/kueue/issues/10167) (RayCluster scheduling gates & preemption) | Kueue supports selective partial preemption callbacks and dynamic slice re-expansion natively. |
| **`pkg/spotinterruption`** | **KubeRay** | • [ray-project/kuberay#5233](https://github.com/ray-project/kuberay/issues/5233) (Fast fallback on Spot capacity exhaustion)<br/>• [ray-project/kuberay#5325](https://github.com/ray-project/kuberay/issues/5325) (scaleStrategy.workersToDelete downscale sync)<br/>• [ray-project/kuberay#4570](https://github.com/ray-project/kuberay/pull/4570) (Replicas and workersToDelete synchronization) | KubeRay operator natively watches cloud Spot interruption events and adjusts `workerGroupSpec`. |
| **`pkg/actorprotect`** | **Kubernetes** & **KubeRay** | • [Kubernetes KEP-2258](https://github.com/kubernetes/enhancements/tree/master/keps/sig-apps/2258-pod-deletion-cost) (Pod Deletion Cost)<br/>• [ray-project/kuberay#5325](https://github.com/ray-project/kuberay/issues/5325) (Stateful actor-aware scale-down) | KubeRay autoscaler directly annotates busy actor pods or coordinates with K8s pod deletion costs. |
| **`cmd/test-nodesim`** | **Testing Harness** | Test-only virtual Kubelet fixture for local Kind/CI execution. Compiled separately as `bin/test-nodesim`. | Replaced by cloud provider emulators (e.g. Floci) during hardware integration runs. |

---

## 5. License

Apache License 2.0. See [LICENSE](LICENSE) for details.
