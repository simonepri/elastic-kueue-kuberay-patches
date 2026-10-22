# Elastic Kueue & KubeRay Patches

[![CI](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/ci.yaml/badge.svg)](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/ci.yaml)
[![Release Please](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/release-please.yaml/badge.svg)](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/release-please.yaml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Tested on Kueue](https://img.shields.io/badge/tested%20on%20kueue-v0.20.2-blue)](https://github.com/kubernetes-sigs/kueue/releases/tag/v0.20.2)
[![Tested on KubeRay](https://img.shields.io/badge/tested%20on%20kuberay-v1.7.1-blue)](https://github.com/ray-project/kuberay/releases/tag/v1.7.1)
[![Tested on Karpenter](https://img.shields.io/badge/tested%20on%20karpenter-v1.15.0-blue)](https://github.com/kubernetes-sigs/karpenter/releases/tag/v1.15.0)

Production patchsets for running elastic, multi-tenant Ray clusters on Kubernetes with [Kueue](https://github.com/kubernetes-sigs/kueue), [KubeRay](https://github.com/ray-project/kuberay), and [Karpenter](https://github.com/kubernetes-sigs/karpenter).

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
          | (1) Partial Preemption:                     | (2) Actor Protection:
          |     Trims elastic workers to                |     Annotates pods with
          |     minReplicas; preserves                  |     pod-deletion-cost
          |     running Ray head                        |     to protect busy actors
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
| **1** | `kubernetes-sigs/kueue` | [`0001-partial-preemption.patch`](patches/kueue/0001-partial-preemption.patch) | Binary all-or-nothing preemption terminates the entire Ray cluster when higher-priority jobs arrive. Also prevents borrowing workloads from being reclaimed proportionally. | Schedules partial preemption down to `minReplicas` (`minCount`), evicting only surplus elastic worker pods while keeping the Ray head and state intact. Reclaims cohort borrowed quota proportionally. | [`tests/scenarios/kueue/01-partial-preemption/01-collaborative-drain`](tests/scenarios/kueue/01-partial-preemption/01-collaborative-drain)<br>[`tests/scenarios/kueue/01-partial-preemption/02-min-viable-guard`](tests/scenarios/kueue/01-partial-preemption/02-min-viable-guard)<br>[`tests/scenarios/kueue/01-partial-preemption/03-cohort-reclaim`](tests/scenarios/kueue/01-partial-preemption/03-cohort-reclaim) |
| **2** | `kubernetes-sigs/kueue` | [`0002-elastic-reexpansion.patch`](patches/kueue/0002-elastic-reexpansion.patch) | Admitted Workload status and pod set counts are immutable; when competing workloads terminate, previously trimmed elastic clusters remain permanently shrunken. | Allows in-place pod set assignment mutations via admission webhooks and watches cluster queue releases to automatically re-expand workloads to their original spec count. | [`tests/scenarios/kueue/02-elastic-reexpansion/01-reexpansion`](tests/scenarios/kueue/02-elastic-reexpansion/01-reexpansion) |
| **3** | `kubernetes-sigs/kueue` | [`0003-karpenter-jit-reservation.patch`](patches/kueue/0003-karpenter-jit-reservation.patch) | Kueue relies on standard cluster autoscalers reactively; cold-start gang workloads stall without JIT capacity, and newly provisioned nodes get stolen by rogue unmanaged pods. | Implements an in-tree Karpenter AdmissionCheck controller that pre-provisions `NodeClaim` resources for gang workloads and isolates nodes with `kyield.io/claimed-by=<gang-id>` reservation taints. | [`tests/scenarios/kueue/03-karpenter-jit-reservation/01-cold-start-gang`](tests/scenarios/kueue/03-karpenter-jit-reservation/01-cold-start-gang)<br>[`tests/scenarios/kueue/03-karpenter-jit-reservation/02-anti-theft-taint`](tests/scenarios/kueue/03-karpenter-jit-reservation/02-anti-theft-taint) |
| **4** | `ray-project/kuberay` | [`0001-actor-protect.patch`](patches/kuberay/0001-actor-protect.patch) | The Ray autoscaler terminates worker pods without Kubernetes awareness, killing pods actively executing stateful actor workloads during scale-down. | Operator inspects worker `ray.io/actor-state` labels and manages `controller.kubernetes.io/pod-deletion-cost` (e.g. `+1000` for busy actors, `-1000` for idle workers). | [`tests/scenarios/kuberay/01-actor-protect/01-actor-aware-drain`](tests/scenarios/kuberay/01-actor-protect/01-actor-aware-drain) |
| **5** | `ray-project/kuberay` | [`0002-spot-interruption.patch`](patches/kuberay/0002-spot-interruption.patch) | Cloud spot interruptions (AWS 2-minute notice / GCP 30-second notice) trigger abrupt node termination and worker pod eviction without coordinated state drain. | Operator intercepts spot interruption notices, flags affected Ray pods, and coordinates graceful actor migration before the physical node is terminated. | [`tests/scenarios/kuberay/02-spot-interruption/01-spot-termination-drain`](tests/scenarios/kuberay/02-spot-interruption/01-spot-termination-drain) |
| **6** | `ray-project/kuberay` | [`0003-scalegate.patch`](patches/kuberay/0003-scalegate.patch) | Ray autoscaler requests scale-up beyond ClusterQueue quota and cohort limits, leading to stuck pending pods and quota starvation for other tenants. | ScaleGate reconciler clamps `workerGroupSpecs.maxReplicas` to the ClusterQueue nominal quota plus cohort borrowing ceiling, keeping autoscaling strictly within budget. | [`tests/scenarios/kuberay/03-scalegate-quota/01-scaleup-clamping`](tests/scenarios/kuberay/03-scalegate-quota/01-scaleup-clamping) |

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
| **09-shared-kueue-fleet-fairness** | [`tests/scenarios/distributed/09-shared-kueue-fleet-fairness`](tests/scenarios/distributed/09-shared-kueue-fleet-fairness) | Two-tier fleet queue architecture: autonomous cell-local compute (Tier 1) and centralized spot fleet fair sharing via Shared Kueue cohort on `ctrl` (Tier 2); validates dynamic borrowing, fair-share cohort reclaim, and ScaleGate fleet clamping without `ctrl` running user pods. |
| **10-interlink-cloudvm-virtual-kubelet** | [`tests/scenarios/distributed/10-interlink-cloudvm-virtual-kubelet`](tests/scenarios/distributed/10-interlink-cloudvm-virtual-kubelet) | End-to-end hybrid Ray cluster bursting onto an InterLink Virtual Kubelet node (`interlink-provider-cloudvm`) under realistic network and provisioning latencies (cold-start VM boot/pull delay, GCS RPC timeout tolerance, and 15s termination grace latency without double-counted quota or head eviction). |

---

## Dual Versioning Scheme

Images published by this repository use a compound tag format:

$$\text{Image Tag} = \langle\text{upstream-version}\rangle\text{-p}\langle\text{patch-version}\rangle$$

Examples:
- `ghcr.io/simonepri/kueue:v0.20.2-p0.2.0`
- `ghcr.io/simonepri/kuberay-operator:v1.7.1-p0.2.0`

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
The patched operator requires permissions to watch `ConfigMap` resources (for spot interruption notices) and Kueue `ClusterQueue` / `LocalQueue` resources (for ScaleGate quota clamping):

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
    resources: ["clusterqueues", "localqueues"]
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
  --set controllerManager.manager.image.tag=v0.20.2-p0.2.0
```

**Using Official Manifests:**
```bash
curl -sL "https://github.com/kubernetes-sigs/kueue/releases/download/v0.20.2/manifests.yaml" | \
  sed -e "s|registry.k8s.io/kueue/kueue:v0.20.2|ghcr.io/simonepri/kueue:v0.20.2-p0.2.0|g" | \
  kubectl apply --server-side -f -
```

#### Required RBAC for Karpenter JIT AdmissionCheck
When using the in-tree Karpenter AdmissionCheck controller for JIT gang pre-provisioning, grant Kueue permission to manage `karpenter.sh/v1` `NodeClaim` resources:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kueue-karpenter-nodeclaims
rules:
  - apiGroups: ["karpenter.sh"]
    resources: ["nodeclaims", "nodeclaims/status"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
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
To enable JIT gang pre-provisioning, define the AdmissionCheck and associate it with your `ClusterQueue`:

```yaml
apiVersion: kueue.x-k8s.io/v1beta1
kind: AdmissionCheck
metadata:
  name: karpenter-provision
spec:
  controllerName: kyield.io/admission-check
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

# Tear down the local Kind cluster
mise run cluster:down
```

---

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
