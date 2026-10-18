# Elastic Kueue & KubeRay Patches

[![CI](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/ci.yaml/badge.svg)](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/ci.yaml)
[![Release Please](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/release-please.yaml/badge.svg)](https://github.com/simonepri/elastic-kueue-kuberay-patches/actions/workflows/release-please.yaml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Tested on Kueue](https://img.shields.io/badge/tested%20on%20kueue-v0.10.1-blue)](https://github.com/kubernetes-sigs/kueue/releases/tag/v0.10.1)
[![Tested on KubeRay](https://img.shields.io/badge/tested%20on%20kuberay-v1.2.2-blue)](https://github.com/ray-project/kuberay/releases/tag/v1.2.2)
[![Tested on Karpenter](https://img.shields.io/badge/tested%20on%20karpenter-v1.2.1-blue)](https://github.com/kubernetes-sigs/karpenter/releases/tag/v1.2.1)

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
| **1** | `kubernetes-sigs/kueue` | *Pending* | Binary all-or-nothing preemption terminates the entire Ray cluster when higher-priority jobs arrive. Also prevents borrowing workloads from being reclaimed proportionally. | *Pending* | *Pending* |
| **2** | `kubernetes-sigs/kueue` | *Pending* | Admitted Workload status and pod set counts are immutable; when competing workloads terminate, previously trimmed elastic clusters remain permanently shrunken. | *Pending* | *Pending* |
| **3** | `kubernetes-sigs/kueue` | *Pending* | Kueue relies on standard cluster autoscalers reactively; cold-start gang workloads stall without JIT capacity, and newly provisioned nodes get stolen by rogue unmanaged pods. | *Pending* | *Pending* |
| **4** | `ray-project/kuberay` | *Pending* | The Ray autoscaler terminates worker pods without Kubernetes awareness, killing pods actively executing stateful actor workloads during scale-down. | *Pending* | *Pending* |
| **5** | `ray-project/kuberay` | *Pending* | Cloud spot interruptions (AWS 2-minute notice / GCP 30-second notice) trigger abrupt node termination and worker pod eviction without coordinated state drain. | *Pending* | *Pending* |
| **6** | `ray-project/kuberay` | *Pending* | Ray autoscaler requests scale-up beyond ClusterQueue quota and cohort limits, leading to stuck pending pods and quota starvation for other tenants. | *Pending* | *Pending* |

---

## Dual Versioning Scheme

Images published by this repository use a compound tag format:

$$\text{Image Tag} = \langle\text{upstream-version}\rangle\text{-p}\langle\text{patch-version}\rangle$$

Examples:
- `ghcr.io/simonepri/kueue:v0.10.1-p0.1.0`
- `ghcr.io/simonepri/kuberay-operator:v1.2.2-p0.1.0`

When [Renovate](renovate.json) detects an upstream release, it opens a PR updating the upstream baseline. Once merged, [Release Please](release-please-config.json) increments the patch version independently.

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
