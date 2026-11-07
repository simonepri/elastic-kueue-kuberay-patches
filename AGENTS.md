# Meta

## Context

- **Governs patch development across Kueue, KubeRay, and Ray**: this document defines authoritative architectural invariants, patch engineering standards, diff conventions, and verification workflows for the `elastic-kueue-kuberay-patches` repository.
- **Pinned upstream versions**:
  - Kueue: `v0.20.5`
  - KubeRay: `v1.7.2`
  - Ray: `2.60.0`
  - Karpenter: `v1.15.1`
  - InterLink: `0.6.2`

# Security & Confidentiality

## Principles

- **Withhold private corporate identity and colleague handles**: never mention internal organization names, private repositories, internal hostnames, cluster names, internal cloud accounts, or colleague GitHub handles anywhere in public repository code, patches, comments, git commit messages, or documentation.
- **Enforce upstream open-source attribution standards**: attribute upstream issues, PRs, and KEPs using public kubernetes-sigs or ray-project identifiers only.

# Patch Engineering

## Principles

- **Structure patches as atomic, independent units**: each patch must represent a single responsibility, bug fix, or feature extension that can compile and apply cleanly.
- **Order bug fixes strictly before features**: patches must be numerically sequenced such that bug fixes (`000X-fix-...`) precede feature extensions (`000X-feat-...`).
- **Enforce code-first diff layout**: every patch must place production code changes first, followed strictly by accompanying unit and integration tests (`*_test.go`, `test/**`). Human reviewers and tools must see functional implementations before test assertions.
- **Colocate patch extensions in dedicated patch-owned files**: place new structs, interfaces, constants, and helper functions in dedicated new files owned by the patch (e.g., `pkg/workload/partial_preemption.go`, `overhead.go`, `flavor_split.go`), and edit upstream files only at minimal hook and call sites.

## Decisions

- **Preserve upstream feature gate defaults**: vanilla Kueue and KubeRay behavior must remain unchanged when feature gates are left at upstream defaults; every custom behavior must sit behind explicit feature gates (`PartialPreemption`, `ElasticJobsViaWorkloadSlicesFlavorSplit`, etc.).
- **Regenerate patches against a pristine checkout**: when editing a patch, re-apply the stack up to that patch, edit the code, verify tests, and regenerate the patch by diffing production code first followed by tests using git pathspecs (e.g. `git diff -- . ':(exclude)*_test.*' ':(exclude)test/**'` followed by `git diff -- '*_test.*' 'test/**'`).

# Architecture & Invariants

## Principles

- **Write admission status once**: only the Kueue scheduler sets `status.admission`; no controller or webhook may mutate admitted counts or resource usages post-admission.
- **Release quota dynamically only after pods terminate**: never release quota based on intent; quota drops only when `status.reclaimablePods` increments after excess worker pods have fully terminated, or when a workload is evicted.
- **Protect Ray head state during preemption**: partial preemption must shrink elastic worker groups down to `minReplicas` floor while keeping the Ray head pod alive and un-evicted.
- **Clamp worker pod creation at admission boundaries**: the KubeRay operator (via ScaleGate) must clamp worker pod creation to the currently admitted Workload counts, preventing un-admitted or unschedulable pod thrashing.
- **Isolate JIT provisioned capacity with anti-theft taints**: nodes provisioned by the Karpenter admission check must carry `karpenter.sh/claimed-by` taints matching the admitted workload's UID to prevent capacity theft by unmanaged pods.
- **Delay TAS topology assignment until nodes register**: topology-aware scheduling must delay assigning node topologies until provisioned Karpenter nodes register in the cluster.

# Testing & Verification

## Principles

- **Verify full-stack integration with all components active**: end-to-end integration tests must run on a real cluster (Kind) with the patched Kueue controller manager, patched KubeRay operator, and the custom Ray container image built from the patched Ray wheel.
- **Require zero race conditions**: all Go unit tests for Kueue and KubeRay must pass with `-race` enabled.

## Decisions

- **Verify clean patch application before testing**: always verify that patches apply cleanly from scratch with `rm -rf third_party/<repo> && mise run patch:<repo>`.
- **Run static validation gates before pushing**: pass `mise run test:checks` before committing.
- **Write commit messages in problem-then-solution format**: commit subjects must follow unscoped conventional commits (`type: summary`); bodies must describe the problem in one paragraph and the solution in a second paragraph.
