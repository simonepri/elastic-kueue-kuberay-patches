# Kueue Elastic Patch Stack Contract

The patch order, field owners, annotation keys, Go interfaces, and feature gate that every Kueue patch in this directory builds against, plus the acceptance tests that patches still to come must pass.

## Invariants

Every patch keeps these, and its tests check the ones it touches:

1. **The admission is written once.** Only the scheduler sets `status.admission`, and no patch changes its counts or resource usage afterwards. A workload shrinks only by lowering `spec.podSets[].count` (upstream elastic scale-down), by raising `status.reclaimablePods`, or through a new workload slice.
2. **Usage comes only from `workload.Info`.** Preemption code adds and removes whole `workload.Info` objects, and a shrunk victim is modelled as a second, smaller `workload.Info` (`Target.Remaining`), never by editing a `Target` or the cached Workload.
3. **Quota is released only after pods stop.** A partial preemption request releases nothing; quota drops when `status.reclaimablePods` is raised after the pods above the target are gone, or when the workload is evicted.
4. **`minCount` keeps its upstream meaning:** the partial admission floor, and the KEP-12100 scale-up baseline. The floor partial preemption may shrink to is a separate annotation.
5. **Kueue never writes an elastic job's size.** No patch writes `workerGroupSpecs[].replicas`, `minReplicas`, `maxReplicas`, or `workersToDelete`.
6. **Job templates carry only stable data that a webhook re-derives on every write.** Per-slice placement, such as flavor node selectors and tolerations, goes on the pods.
7. **Gate defaults stay upstream's.** With every gate at its default, each upstream test that passes on vanilla Kueue passes on the stack; deployments set gates in their configuration (see [Feature gates](../../readme.md#feature-gates)).

## Stack order

`git apply` runs the patches in file name order. Each patch is generated with `git diff` against the tree with every earlier patch applied, and a patch is regenerated when an earlier one changes.

| File | ID | Purpose | Upstream files it may touch | Depends on |
| :--- | :-: | :--- | :--- | :--- |
| `0001-workload-scale-down-below-min-count.patch` | R7 | Backport of [kubernetes-sigs/kueue#16742](https://github.com/kubernetes-sigs/kueue/pull/16742): a scale-down below `minCount` caps `minCount` instead of failing validation | `pkg/workloadslicing/manager.go`, `pkg/workload/podsetscounts.go`, `pkg/webhooks/workload_webhook.go` | none |
| `0002-ray-min-count-migration.patch` | R0 | Temporary: Ray Workloads holding quota ignore `minCount` in the equivalence check, so jobs admitted by p0.6.x and earlier keep running | `pkg/util/equality/podset.go`, `pkg/controller/jobs/{raycluster,rayjob,rayservice}/*_controller.go` | none |
| `0003-karpenter-jit-reservation.patch` | | Karpenter JIT reservation admission check | unchanged | none |
| `0004-deployment-queue-mutation.patch` | | Queue and priority class changes on running Deployments | unchanged | none |
| `0005-topology-aware-reclaim.patch` | | Topology-aware reclaim retry; evicts elastic victims whole | unchanged | none |
| `0006-elastic-flavor-on-pods.patch` | R2 | A moved elastic PodSet's flavor node selectors and tolerations go on each pod before ungating, never on the template; `ElasticJobsViaWorkloadSlicesFlavorChangeFromZero` stays a configuration choice | `pkg/controller/elasticjobs/elastic_job_ungater.go`, `pkg/controller/jobframework/reconciler.go` (`deferAdmissionCheckNodeSelectorsToPods`) | none |
| `0007-elastic-template-restamp.patch` | R1 | The RayCluster webhook re-stamps the PodSet label and slice name annotation on a running elastic cluster's templates, so a re-applied manifest does not leave new workers gated | `pkg/controller/jobs/raycluster/raycluster_webhook.go`, optionally `pkg/controller/jobs/rayservice/rayservice_webhook.go` | R2 |
| `0008-partial-preemption-reclaim-targets.patch` | R3 | Reclaim targets: the `PartialPreemption` gate, `JobWithPartialStop`, the RayCluster stopper, the ungater cap and quota release, clearing on quota release | `pkg/features/kube_features.go`, `pkg/workloadslicing/pods.go`, `pkg/controller/jobframework/reconciler.go`, `pkg/controller/jobs/raycluster/raycluster_controller.go`, `pkg/controller/elasticjobs/elastic_job_ungater.go`, `pkg/controller/core/workload_controller.go` | none |
| `0009-partial-preemption-floors.patch` | R4 | Floor and step annotations: floor = `minReplicas` x `numOfHosts`, step = `numOfHosts`, single-host worker groups of elastic RayClusters only | `pkg/controller/jobframework/reconciler.go` (`ConstructWorkload`), `pkg/controller/jobs/raycluster/common.go` | R3 (gate) |
| `0010-partial-preemption-search.patch` | R5 | Partial preemption in the classical strategy: offer an elastic victim shrunk to its floor first, grow it back in steps during fill-back, evict it whole when that is not enough; whole eviction after a timeout | `pkg/scheduler/preemption/policy/types.go`, `preemption.go`, `classical_strategy.go`, `preempted_workloads.go`, `preemption_oracle.go`, `topology_retry*.go`, `pkg/scheduler/scheduler.go`, `pkg/scheduler/assignment/native/native.go` | R3, R4, 0005 |
| `0011-elastic-regrow-after-reclaim.patch` | R6 | Regrow after a reclaim: a scale-up probe once the quota is released, probe names from the predecessor slice's UID, the after-reclaim baseline, and no probe admission while the recorded preemptor is pending | `pkg/workloadslicing/manager.go`, `pkg/controller/jobframework/reconciler.go` (`prepareWorkloadSliceForScaleUp`), `pkg/scheduler/scheduler.go` | R3, R7 |
| `0012-multi-host-partial-scale-up.patch` | R8 | Partial scale-up grants whole replicas of multi-host worker groups: lifts R4's single-host restriction and writes `kueue.x-k8s.io/podset-count-steps` whenever `ElasticJobsViaWorkloadSlicesWithPartialReplicaScaleUp` is on | `pkg/scheduler/scheduler.go` (`getAssignments`, `effectiveReducerPodSets`), `pkg/scheduler/flavorassigner/podset_reducer.go`, `pkg/controller/jobs/raycluster/common.go` | R4, R6 |

Rules for every patch:

- Put new types, constants, and helpers in new files the patch owns, such as `pkg/workload/partial_preemption.go`, and edit upstream files only at call sites. Two patches then never edit the same declaration block.
- Gate new behavior on `PartialPreemption` (R3, R4, R5, R6) or on the upstream gate the behavior belongs to (R2, R8), and keep R1 limited to elastic RayClusters.
- Add tests that fail without the patch, a readme row, and the changed packages to `mise run test:kueue` or `test:kueue-integration`.
- When an upstream PR that a patch mirrors merges, rebase on the merged version and delete what it replaces.

## Field ownership

| Field | Writer | Readers |
| :--- | :--- | :--- |
| `workerGroupSpecs[].replicas`, `workersToDelete` | the Ray autoscaler, or the user for clusters without it | KubeRay; Kueue derives Workload `spec.podSets[].count` from `replicas` |
| `minReplicas`, `maxReplicas`, template body | the user or GitOps | KubeRay, the autoscaler, R4 (the floor) |
| Template scheduling gate, `kueue.x-k8s.io/podset` label, slice name annotation | Kueue's RayCluster webhook, on every write (R1) | KubeRay, ElasticJobUngater |
| Flavor node selectors and tolerations | ElasticJobUngater, on each pod (R2) | kube-scheduler |
| Workload `spec.podSets[].count`, `minCount` | the job reconciler, with upstream semantics (R7 caps `minCount` on scale-down) | everyone, through `workload.Info` |
| `kueue.x-k8s.io/reclaim-min-counts`, `kueue.x-k8s.io/podset-count-steps` | the job reconciler (R4; R8 for multi-host groups) | R5, R8 |
| `kueue.x-k8s.io/reclaim-target-counts`, `kueue.x-k8s.io/reclaim-preemptor`, `kueue.x-k8s.io/reclaim-requested-at` | the preemptor (R5); cleared by the Workload controller (R3) | R3 (stopper, ungater), R5, R6 |
| `status.admission` | the scheduler only; upstream may later trim `topologyAssignment` ([kubernetes-sigs/kueue#17374](https://github.com/kubernetes-sigs/kueue/pull/17374)) | everyone |
| `status.reclaimablePods` | ElasticJobUngater's partial reclaim release (R3), the only writer for Ray | `workload.Info` |
| Running pods above a reclaim target | deleted by the RayCluster stopper (R3); KubeRay recreates them, gated | ElasticJobUngater |

## Annotation keys

All are Workload annotations. Count lists use the format of [kubernetes-sigs/kueue#17484](https://github.com/kubernetes-sigs/kueue/pull/17484): `<podSet>=<count>[,<podSet>=<count>]`, PodSets sorted by name, counts in pods. A malformed entry is ignored.

| Key | Value | Written | Cleared | Constant (file) |
| :--- | :--- | :--- | :--- | :--- |
| `kueue.x-k8s.io/reclaim-target-counts` | count list: the pod count each shrunk PodSet goes down to | by R5 on the victim, with preemption expectations, never raising a pending target | by R3 once the Workload no longer holds quota, after clearing the `reclaimablePods` it set | `constants.ReclaimTargetCountsAnnotation` (`pkg/constants/partial_preemption.go`, R3) |
| `kueue.x-k8s.io/reclaim-preemptor` | `<namespace>/<name>` of the preemptor Workload | by R5, together with the target | by R3, together with the target | `constants.ReclaimPreemptorAnnotation` (same file, R3) |
| `kueue.x-k8s.io/reclaim-requested-at` | RFC 3339 time the target was written; R5 evicts the victim whole once a pending target is older than its timeout | by R5, together with the target | by R3, together with the target | `constants.ReclaimRequestedAtAnnotation` (same file, R3) |
| `kueue.x-k8s.io/reclaim-min-counts` | count list: the fewest pods each PodSet may keep; a PodSet missing from it is only evicted whole | by R4 when it builds the Workload, and patched when the job's floor changes | never; a new slice gets its own | `constants.ReclaimMinCountsAnnotation` (`pkg/constants/reclaim_floors.go`, R4) |
| `kueue.x-k8s.io/podset-count-steps` | count list: the pod count each PodSet shrinks and grows by; a missing PodSet has step 1 | as above | never | `constants.PodSetCountStepsAnnotation` (same file, R4) |

`kueue.x-k8s.io/reclaim-target-counts` is the only key [kubernetes-sigs/kueue#17484](https://github.com/kubernetes-sigs/kueue/pull/17484) defines. The floor follows the `reclaimMinCount` field that the [KEP-975 draft](https://github.com/kubernetes-sigs/kueue/pull/14589) proposes, so it can become that field when the KEP lands.

## Go interfaces

R3 adds, in `pkg/controller/jobframework/partial_stop.go`, the interface of [kubernetes-sigs/kueue#17484](https://github.com/kubernetes-sigs/kueue/pull/17484) unchanged:

```go
// JobWithPartialStop is implemented by elastic jobs that partial preemption can shrink.
type JobWithPartialStop interface {
	// StopPartially brings each PodSet in targets down to its target count without changing
	// the job's desired count, so the recreated pods stay gated. It makes no API call when the
	// PodSets are already at their targets, and returns whether it stopped any pod.
	StopPartially(ctx context.Context, c client.Client, wl *kueue.Workload, targets workload.PodSetsCounts) (bool, error)
}
```

RayCluster implements it by deleting running pods above the target in whole `ray.io/worker-group-replica-name` groups, lowest `controller.kubernetes.io/pod-deletion-cost` first, then newest. R3 also adds, in `pkg/workload/partial_preemption.go`, `ParsePodSetCounts(string) PodSetsCounts`, `FormatPodSetCounts(PodSetsCounts) string`, `ReclaimTargetCounts`, `SetReclaimTargetCounts`, `PendingReclaimTargetCounts`, `IsPartiallyPreempted`, and `ReclaimablePodsForTargets`, with #17484's semantics.

R4 adds, in `pkg/workload/reclaim_floors.go`, the type and the annotation reader and writer:

```go
// ReclaimFloor bounds how partial preemption may shrink a PodSet.
type ReclaimFloor struct {
	// MinCount is the fewest pods the PodSet may keep: a multiple of Step, at most the PodSet's count.
	MinCount int32
	// Step is the pod count the PodSet shrinks and grows by; at least 1.
	Step int32
}

// ReclaimFloors reads the reclaim-min-counts and podset-count-steps annotations.
func ReclaimFloors(wl *kueue.Workload) map[kueue.PodSetReference]ReclaimFloor

// SetReclaimFloors writes both annotations, or removes them when floors is empty.
func SetReclaimFloors(wl *kueue.Workload, floors map[kueue.PodSetReference]ReclaimFloor)
```

and, in `pkg/controller/jobframework/reclaim_floors.go`, the optional interface the job reconciler calls when it builds a Workload:

```go
// JobWithReclaimFloors is implemented by elastic jobs whose PodSets partial preemption may shrink.
type JobWithReclaimFloors interface {
	// ReclaimFloors returns the floor of each PodSet partial preemption may shrink.
	// A PodSet it leaves out is only evicted whole.
	ReclaimFloors() map[kueue.PodSetReference]workload.ReclaimFloor
}
```

## Preemption seam

R5 adds `Remaining` to `policy.Target` and the helpers below in `pkg/scheduler/preemption/policy/partial.go`. `Remaining` and `RemoveFrom`/`AddTo` match [kubernetes-sigs/kueue#17484](https://github.com/kubernetes-sigs/kueue/pull/17484).

```go
type Target struct {
	// existing fields unchanged

	// Remaining is the part of the workload that stays admitted when the target is shrunk
	// instead of evicted: the victim's workload.Info with each shrunk PodSet's TotalRequests
	// replaced by PodSetResources.ScaledTo(target count), keeping its whole TAS usage. Nil for
	// a whole eviction.
	Remaining *workload.Info
}

// RemoveFrom removes the target's workload from the snapshot and adds back Remaining.
func (t *Target) RemoveFrom(snapshot *schdcache.Snapshot)

// AddTo reverts RemoveFrom.
func (t *Target) AddTo(snapshot *schdcache.Snapshot)

// FreedUsage returns the usage RemoveFrom frees: the workload's usage minus Remaining's.
func (t *Target) FreedUsage() workload.Usage

// SimulateRemoval calls RemoveFrom on each target and returns a function that calls AddTo in reverse order.
func SimulateRemoval(snapshot *schdcache.Snapshot, targets []*Target) (revert func())

// EvictedWorkloads returns the workloads of the targets without Remaining, the only
// ones whose pods leave the scheduling simulator.
func EvictedWorkloads(targets []*Target) []*workload.Info
```

`preemption.PreemptedWorkloads` becomes `map[workload.Reference]*Target`, and `Targets()` replaces `Workloads()`, so a shrunk victim's `Remaining` reaches the scheduler's own checks. Every site that takes a victim out of the snapshot goes through the seam:

| # | Site | Change |
| :-: | :--- | :--- |
| 1 | `policy.YieldFromSnapshot` (all strategies) | `t.RemoveFrom(snapshot)` |
| 2 | `restoreSnapshot`, `fillBackWorkloads` (`preemption.go`) | `AddTo`/`RemoveFrom`; fill-back grows a shrunk target's `Remaining` back step by step while the preemptor still fits |
| 3 | the preemption oracle (`preemption_oracle.go`) | `SimulateRemoval(snapshot, candidates)` |
| 4 | `fits` (`scheduler.go`) | `SimulateRemoval` over `MergeWithTargets(newTargets).Targets()` |
| 5 | `simulateOtherPreemptions` (`scheduler.go`) | `SimulateRemoval`, and `SimulatePodRemoval` only for `EvictedWorkloads` |
| 6 | `nativePlanner.updateAssignmentForTAS` (`assignment/native/native.go`) | as site 5 |
| 7 | fair-sharing share and verify (`fair_strategy.go`, `fairsharing/target.go`) | unchanged: the fair-sharing and configurable strategies yield whole targets only, which a test asserts |
| 8 | 0005's topology retry (`topology_retry*.go`) | starts from a snapshot restored with `AddTo`; candidate usage comes from `FreedUsage()`, so a shrunk candidate frees quota only |

## Feature gate

R3 adds the gate that [kubernetes-sigs/kueue#17484](https://github.com/kubernetes-sigs/kueue/pull/17484) adds, at this fork's version:

```go
// Enables preemption to shrink elastic workloads to their reclaim floor before evicting them.
PartialPreemption featuregate.Feature = "PartialPreemption"

PartialPreemption: {{Version: version.MustParse("0.20"), Default: false, PreRelease: featuregate.Alpha}},
// dependencies
PartialPreemption: {ElasticJobsViaWorkloadSlices, ReclaimablePods},
```

With the gate off, R3 to R6 change nothing: no floor annotation is written, no target is set, and the reconciler, ungater, and scheduler follow upstream code paths.

## Acceptance tests

These scenarios and cases cover behavior the stack lost when the earlier partial preemption patches were removed. Chainsaw scenarios stay in the tree with `spec.skip: true` and a comment naming the patch that runs them again; that patch removes the skip and rewrites the assertions shown.

| Owner | Test | Must show |
| :-: | :--- | :--- |
| R5 | [`kueue/01-partial-preemption/01-collaborative-drain`](../../tests/scenarios/kueue/01-partial-preemption/01-collaborative-drain), [`kueue/01-partial-preemption/03-cohort-reclaim`](../../tests/scenarios/kueue/01-partial-preemption/03-cohort-reclaim) | the victim keeps `replicas`, its pods above the target are deleted and recreated gated, its `reclaimablePods` rise, and only then is the preemptor admitted |
| R5 | a victim whose shrink to its floor is not enough, replacing the removed `02-min-viable-guard` scenario | the victim is evicted whole and the preemptor admitted, the opposite of the removed scenario |
| R5 | [`distributed/05-spot-elastic-reexpansion`](../../tests/scenarios/distributed/05-spot-elastic-reexpansion), [`distributed/09-shared-kueue-fleet-fairness`](../../tests/scenarios/distributed/09-shared-kueue-fleet-fairness), [`distributed/10-interlink-cloudvm-virtual-kubelet`](../../tests/scenarios/distributed/10-interlink-cloudvm-virtual-kubelet) | as the first row, with re-expansion steps owned by R6 |
| R5 | unit cases from [#73](https://github.com/simonepri/elastic-kueue-kuberay-patches/pull/73) and its reviews | `[shrunk elastic, W]` found when the elastic victim comes first and shrinking alone is not enough; no whole eviction where a shrink suffices; a TAS shrink plan that the planner and `fits` both accept; multi-PodSet victims charged per PodSet; reclaimable pods and nil assignment counts counted as in `workload.Info`; the cached Workload never mutated; batch Jobs with `minCount` never shrunk; fair sharing returning vanilla's targets |
| R3 | stopper and release unit and envtest cases | whole replica groups deleted, cheapest deletion cost first; no quota released while a pod above the target runs; targets and `reclaimablePods` cleared when quota is released |
| R3, R5 | a chainsaw scenario with `enableInTreeAutoscaling: true` | the autoscaler does not undo the shrink, and the preemptor and victim never run over quota together; required before a deployment enables `PartialPreemption` |
| R6 | [`kueue/02-elastic-reexpansion/01-reexpansion`](../../tests/scenarios/kueue/02-elastic-reexpansion/01-reexpansion) | a probe regrows the cluster once the preemptor no longer needs the quota, without Kueue writing `replicas` |
| R6 | envtest specs from [#78](https://github.com/simonepri/elastic-kueue-kuberay-patches/pull/78) (pending scale-up, autoscaler scale-down) | a voluntary scale-down and a pending scale-up are never reverted; probe names never collide with an existing slice |
| R1 | [#78](https://github.com/simonepri/elastic-kueue-kuberay-patches/pull/78)'s `kueue/05-elastic-template-reapply` scenario and re-apply envtest spec | after a re-apply that replaces `workerGroupSpecs`, new and replacement workers are ungated |
| R2 | [`kueue/06-elastic-flavor-from-zero/01-scale-up-from-zero`](../../tests/scenarios/kueue/06-elastic-flavor-from-zero/01-scale-up-from-zero) | workers of a moved PodSet run on the new flavor, including when flavors share node label keys |
| R4, R8 | multi-host cases from [#73](https://github.com/simonepri/elastic-kueue-kuberay-patches/pull/73) | floors and grants in whole replicas; a replacement slice always grows on rounded counts |
