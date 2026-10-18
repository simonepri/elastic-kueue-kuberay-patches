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

# 2. Build Kyield binary
make build

# 3. Create Kind cluster and install CRDs
make kind-up
make install-crds

# 4. Run full 9-scenario Chainsaw test suite
make test
```

---

## 4. Upstream Retirement Roadmap

Kyield is explicitly designed as a "thinning-out" shim that evaporates into upstream projects over time:

1. **`pkg/preprovisioner`**: Retires once Kueue's Dynamic Resource Allocation (DRA) or Karpenter's native AdmissionCheck driver stabilizes in v1.37+.
2. **`pkg/scalegate`**: Retires when KubeRay supports the Kueue Elastic Workload protocol ([KubeRay #1850](https://github.com/ray-project/kuberay)).
3. **`pkg/preemption`**: Retires when Kueue introduces a selective/partial preemption callback API for elastic frameworks.
4. **`pkg/spotinterruption`**: Retires when KubeRay's native spot drain controller graduates.
5. **`pkg/actorprotect`**: Retires when KubeRay's internal autoscaler directly synchronizes actor placement with pod deletion scoring.
6. **`pkg/nodesim`**: Test-only simulation controller enabled strictly via `--enable-node-simulator` flag.

---

## 5. License

Apache License 2.0. See [LICENSE](LICENSE) for details.
