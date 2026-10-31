# Kueue Elastic Patch Stack Contract

The patch order, field owners, annotation keys, Go interfaces, and feature gate that every Kueue patch in this directory builds against, plus the acceptance tests that patches still to come must pass.

## Invariants

Every patch keeps these, and its tests check the ones it touches:

1. **The admission is written once.** Only the scheduler sets `status.admission`, and no patch changes its counts or resource usage afterwards. A workload shrinks only by lowering `spec.podSets[].count` (upstream elastic scale-down), by raising `status.reclaimablePods`, or through a new workload slice.
2. **Usage comes only from `workload.Info`.** Preemption code adds and removes `workload.Info` objects, or the quota-only or TAS-only part of one (0005's retry), and a shrunk victim is modelled as a second, smaller `workload.Info` (`Target.Remaining`), never by editing a `Target` or the cached Workload.
3. **Quota is released only after pods stop.** A partial preemption request releases nothing; quota drops when `status.reclaimablePods` is raised after the pods above the target are gone, or when the workload is evicted.
4. **`minCount` keeps its upstream meaning:** the partial admission floor, and the KEP-12100 scale-up baseline. The floor partial preemption may shrink to is a separate annotation.
5. **Kueue never writes an elastic job's size.** No Kueue patch writes `workerGroupSpecs[].replicas`, `minReplicas`, `maxReplicas`, or `workersToDelete`.
6. **Job templates carry only stable data that a webhook re-derives on every write.** Per-slice placement, such as flavor node selectors and tolerations, goes on the pods.
7. **Gate defaults stay upstream's.** With every gate at its default, each upstream test that passes on vanilla Kueue passes on the stack; deployments set gates in their configuration (see [Feature gates](../../readme.md#feature-gates)).

## Stack order

`git apply` runs the patches in file name order. Coding runs in parallel, against this contract; patches merge strictly in stack order, and before a patch merges it is regenerated with `git diff` against the tree with every earlier patch applied. "Rebases on" names the earlier patches that edit the same functions, so their owners expect conflicts there.

| File | ID | Purpose | Upstream files it may touch | Depends on | Rebases on (shared functions) |
| :--- | :-: | :--- | :--- | :--- | :--- |
| `0001-workload-scale-down-below-min-count.patch` | R7 | Backport of [kubernetes-sigs/kueue#16742](https://github.com/kubernetes-sigs/kueue/pull/16742): a scale-down below `minCount` caps `minCount` instead of failing validation | `pkg/workloadslicing/manager.go`, `pkg/workload/podsetscounts.go`, `pkg/webhooks/workload_webhook.go` | none | vanilla |
| `0002-ray-min-count-migration.patch` | R0 | Temporary: Ray Workloads holding quota ignore `minCount` in the equivalence check, so jobs admitted by p0.6.x and earlier keep running | `pkg/util/equality/podset.go`, `pkg/controller/jobs/{raycluster,rayjob,rayservice}/*_controller.go` | none | none |
| `0003-karpenter-jit-reservation.patch` | | Karpenter JIT reservation admission check | unchanged | none | none |
| `0004-deployment-queue-mutation.patch` | | Queue and priority class changes on running Deployments | unchanged | none | none |
| `0005-topology-aware-reclaim.patch` | | Topology-aware reclaim retry; evicts elastic victims whole | unchanged | none | none |
| `0006-elastic-flavor-on-pods.patch` | R2 | A moved elastic PodSet's flavor node selectors and tolerations go on each pod before ungating, never on the template; `ElasticJobsViaWorkloadSlicesFlavorChangeFromZero` stays a configuration choice | `pkg/controller/elasticjobs/elastic_job_ungater.go`, `pkg/controller/jobframework/reconciler.go` (`deferAdmissionCheckNodeSelectorsToPods`) | none | none |
| `0007-elastic-template-restamp.patch` | R1 | The RayCluster webhook re-stamps the PodSet label and slice name annotation on a running elastic cluster's templates, so a re-applied manifest does not leave new workers gated | `pkg/controller/jobs/raycluster/raycluster_webhook.go`, optionally `pkg/controller/jobs/rayservice/rayservice_webhook.go` | R2 | none |
| `0008-partial-preemption-reclaim-targets.patch` | R3 | Reclaim targets: the `PartialPreemption` gate, `JobWithPartialStop`, the RayCluster stopper, the ungater cap and quota release, re-deriving `reclaimablePods` on scale-down, clearing on quota release | `pkg/features/kube_features.go`, `pkg/workloadslicing/pods.go`, `pkg/workloadslicing/manager.go`, `pkg/controller/jobframework/reconciler.go`, `pkg/controller/jobs/raycluster/raycluster_controller.go`, `pkg/controller/elasticjobs/elastic_job_ungater.go`, `pkg/controller/core/workload_controller.go` | none | R2 (`podsToUngate`), R7 (`EnsureWorkloadSlices`) |
| `0009-partial-preemption-floors.patch` | R4 | Floor and step annotations for single-host worker groups of elastic RayClusters: floor = `minReplicas`, step 1 | `pkg/controller/jobframework/reconciler.go` (`ConstructWorkload`), `pkg/workloadslicing/manager.go` (in-place update), `pkg/controller/jobs/raycluster/common.go` | R3 (gate) | R3, R7 (`EnsureWorkloadSlices`) |
| `0010-partial-preemption-search.patch` | R5 | Partial preemption in the classical strategy: offer an elastic victim shrunk to its floor first, grow it back in steps during fill-back, evict it whole when that is not enough; whole eviction after a timeout | `pkg/scheduler/preemption/policy/types.go`, `preemption.go`, `classical_strategy.go`, `classical/candidate_generator.go`, `classical/cache_candidate_generator.go` (`buildBuckets`), `policy/ordering.go` (the evicted-first comparator), `preempted_workloads.go`, `preemption_oracle.go`, `topology_retry*.go`, `pkg/scheduler/scheduler.go`, `pkg/scheduler/assignment/native/native.go` | R3, R4 | 0005 (`getTargets`, the retry, `updateAssignmentForTAS`, `assembleCandidateIterator` in `classical/candidate_generator.go`, `policy/ordering.go`) |
| `0011-elastic-regrow-after-reclaim.patch` | R6 | Regrow after a reclaim: a scale-up probe once the quota is released, probe names from the predecessor slice's UID, the after-reclaim baseline, and no probe admission while the recorded preemptor is pending | `pkg/workloadslicing/manager.go`, `pkg/controller/jobframework/reconciler.go` (`prepareWorkloadSliceForScaleUp`), `pkg/scheduler/scheduler.go` | R3, R7 | R5 (`processEntry`), R3 and R4 (`EnsureWorkloadSlices`) |
| `0012-multi-host-partial-scale-up.patch` | R8 | Partial scale-up grants whole replicas of multi-host worker groups: writes `kueue.x-k8s.io/podset-count-steps` (step = `numOfHosts`) whenever `ElasticJobsViaWorkloadSlicesWithPartialReplicaScaleUp` is on, and extends R4's floors to multi-host groups (floor = `minReplicas` x `numOfHosts`) | `pkg/scheduler/scheduler.go` (`getAssignments`, `effectiveReducerPodSets`), `pkg/scheduler/flavorassigner/podset_reducer.go`, `pkg/controller/jobs/raycluster/common.go` | R4, R6 | 0005 (`getAssignments`), R4 (`raycluster/common.go`), R6 |

Rules for every patch:

- Put new types, constants, and helpers in new files the patch owns, such as `pkg/workload/partial_preemption.go`, and edit upstream files only at call sites.
- Gate new behavior on `PartialPreemption` (R3, R4, R5, R6) or on the upstream gate the behavior belongs to (R2, R8), and keep R1 limited to elastic RayClusters.
- R3 and R4 cover RayCluster only. Elastic RayJobs and RayServices get no floor, so preemption evicts them whole.
- Add tests that fail without the patch, a readme row, and the changed packages to `mise run test:kueue` or `test:kueue-integration`.
- When an upstream PR that a patch mirrors merges, rebase on the merged version and delete what it replaces.

## Field ownership

| Field | Writer | Readers |
| :--- | :--- | :--- |
| `workerGroupSpecs[].replicas`, `workersToDelete` | the Ray autoscaler, or the user for clusters without it | KubeRay; Kueue derives Workload `spec.podSets[].count` from `replicas` |
| `minReplicas`, template body | the user or GitOps | KubeRay, the autoscaler, R4 (the floor) |
| `maxReplicas` | the user or GitOps; the KubeRay ScaleGate patch (`patches/kuberay/0003-scalegate.patch`) clamps it | KubeRay, the autoscaler |
| Template scheduling gate, `kueue.x-k8s.io/podset` label, slice name annotation | Kueue's RayCluster webhook, on every write (R1) | KubeRay, ElasticJobUngater |
| Flavor node selectors and tolerations | ElasticJobUngater, on each pod (R2) | kube-scheduler |
| Workload `spec.podSets[].count`, `minCount` | the job reconciler, with upstream semantics (R7 caps `minCount` on scale-down) | everyone, through `workload.Info` |
| `kueue.x-k8s.io/reclaim-min-counts` | the job reconciler (R4; R8 for multi-host groups) | R5 |
| `kueue.x-k8s.io/podset-count-steps` | the job reconciler (R4; R8 also with `PartialPreemption` off) | R5, R8 |
| `kueue.x-k8s.io/reclaim-target-counts`, `kueue.x-k8s.io/reclaim-preemptor`, `kueue.x-k8s.io/reclaim-requested-at` | the preemptor (R5); lowered on scale-down and cleared by R3 | R3 (stopper, ungater), R5, R6 |
| `status.admission` | the scheduler only; upstream may later trim `topologyAssignment` ([kubernetes-sigs/kueue#17374](https://github.com/kubernetes-sigs/kueue/pull/17374)) | everyone |
| `status.reclaimablePods` | R3 only, for Ray: the ungater's release, and the re-derivation on scale-down below | `workload.Info` |
| Running pods above a reclaim target | deleted by the RayCluster stopper (R3); KubeRay recreates them, gated | ElasticJobUngater |

### Scale-down after a reclaim

`ReclaimablePodsForTargets` sets a PodSet's reclaimable count to `count - target`, and `workload.Info` charges `min(admitted, count - reclaimable)` pods, where `admitted` is the assignment count. The Workload webhook lets a reclaimable count drop only for a PodSet in `scaledDownPodSetNames`, one whose admitted count is above its spec count (`validateReclaimablePodsUpdate`). A later autoscaler scale-down must keep the charge right within that limit.

R3 owns the rule, in the in-place update of `EnsureWorkloadSlices` (`pkg/workloadslicing/manager.go`). When the job lowers a PodSet that has a reclaim target to `newCount`:

- **`newCount` at or above the admitted count:** R3 leaves the slice unchanged and writes nothing. The charge `min(admitted, count - reclaimable)` is already `target`, the pods R3 keeps running. For example, a victim with spec 8, granted 6 by partial admission, target 4 and reclaimable 4 that the autoscaler lowers to 6 stays at spec 8 and is charged 4. Lowering its spec to 6 would need reclaimable 2, which the webhook rejects ("cannot be less than 4") because 6 is not below the admitted 6, and the charge would stay at 2 while 4 pods run.
- **`newCount` below the admitted count:** R3 lowers `count` to `newCount`; then, in the same reconcile and after that spec update succeeds, it lowers the target to `min(target, newCount)` and sets the reclaimable count to `max(0, newCount - target)`, keeping a larger count the job reports itself. The webhook accepts the lower reclaimable count because the PodSet is now in `scaledDownPodSetNames`; written before the spec update, it is rejected. For example, a victim of 8 shrunk to 4 and then scaled to 4 ends at spec 4, target 4, reclaimable 0, charged 4.

Between the two writes the reclaimable count can exceed the new count for one reconcile; `podSetsCountsAfterReclaim` (`pkg/workload/workload.go`) clamps it so the charge never goes negative, and the victim is under-charged until the status write lands.

Because a slice kept at its old spec count no longer matches the job's count, R6 compares the job's count with the reclaim target, not with the slice's spec count, when it decides whether to create a scale-up probe after the release.

## Annotation keys

All are Workload annotations. Count lists use the format of [kubernetes-sigs/kueue#17484](https://github.com/kubernetes-sigs/kueue/pull/17484): `<podSet>=<count>[,<podSet>=<count>]`, PodSets sorted by name, counts in pods. A malformed entry is ignored.

| Key | Value | Written | Cleared | Constant (file) |
| :--- | :--- | :--- | :--- | :--- |
| `kueue.x-k8s.io/reclaim-target-counts` | count list: the pod count each shrunk PodSet goes down to | by R5 on a deep copy of the victim, as `min(existing, new)` per PodSet, without preemption expectations (see below); lowered by R3 on scale-down | by R3 once the Workload no longer holds quota, after clearing the `reclaimablePods` it set | `constants.ReclaimTargetCountsAnnotation` (`pkg/constants/partial_preemption.go`, R3) |
| `kueue.x-k8s.io/reclaim-preemptor` | `<namespace>/<name>` of the preemptor Workload | by R5, together with the target | by R3, together with the target | `constants.ReclaimPreemptorAnnotation` (same file, R3) |
| `kueue.x-k8s.io/reclaim-requested-at` | RFC 3339 time the target was first written; R5 evicts the victim whole once a pending target is older than its timeout | by R5, when it first sets the target | by R3, together with the target | `constants.ReclaimRequestedAtAnnotation` (same file, R3) |
| `kueue.x-k8s.io/reclaim-min-counts` | count list: the fewest pods each PodSet may keep; a PodSet missing from it is only evicted whole | by R4 when it builds the Workload, and by R4 in the in-place update of `EnsureWorkloadSlices` when the job's floor changes | never; a new slice gets its own | `constants.ReclaimMinCountsAnnotation` (`pkg/constants/reclaim_floors.go`, R4) |
| `kueue.x-k8s.io/podset-count-steps` | count list: the pod count each PodSet shrinks and grows by; a missing PodSet has step 1 | as above; independent of the floor, so R8 writes it without one | never | `constants.PodSetCountStepsAnnotation` (same file, R4) |

`kueue.x-k8s.io/reclaim-target-counts` is the only key [kubernetes-sigs/kueue#17484](https://github.com/kubernetes-sigs/kueue/pull/17484) defines. The floor follows the `reclaimMinCount` field that the [KEP-975 draft](https://github.com/kubernetes-sigs/kueue/pull/14589) proposes, so it can become that field when the KEP lands.

Partial targets set no preemption expectations, as in #17484. Upstream observes an expectation only when the victim is evicted or its quota is released (`pkg/cache/queue/manager.go`, the `IsEvicted` branch of `IssuePreemptions`, and `pkg/scheduler/scheduler.go`), so an admitted victim that only gains an annotation would stay "already issued" forever. Because R5 writes `min(existing, new)`, writing the same target again in a later cycle changes nothing.

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

R4 adds separate readers and writers for floors and steps, in `pkg/workload/reclaim_floors.go`:

```go
// ReclaimMinCounts reads kueue.x-k8s.io/reclaim-min-counts.
func ReclaimMinCounts(wl *kueue.Workload) PodSetsCounts

// SetReclaimMinCounts writes it, or removes it when counts is empty.
func SetReclaimMinCounts(wl *kueue.Workload, counts PodSetsCounts)

// PodSetCountSteps reads kueue.x-k8s.io/podset-count-steps; a missing PodSet has step 1.
func PodSetCountSteps(wl *kueue.Workload) PodSetsCounts

// SetPodSetCountSteps writes it, or removes it when steps is empty.
func SetPodSetCountSteps(wl *kueue.Workload, steps PodSetsCounts)
```

and the optional interfaces the job reconciler calls, in `pkg/controller/jobframework/reclaim_floors.go`:

```go
// JobWithReclaimMinCounts is implemented by elastic jobs whose PodSets partial preemption may shrink.
type JobWithReclaimMinCounts interface {
	// ReclaimMinCounts returns the fewest pods each shrinkable PodSet may keep, a multiple
	// of its step and at most its count. A PodSet it leaves out is only evicted whole.
	ReclaimMinCounts() workload.PodSetsCounts
}

// JobWithPodSetCountSteps is implemented by jobs whose PodSets grow and shrink in steps.
type JobWithPodSetCountSteps interface {
	// PodSetCountSteps returns the pod count each PodSet grows and shrinks by, at least 1.
	PodSetCountSteps() workload.PodSetsCounts
}
```

R4 writes the floors when `PartialPreemption` is on, and the steps when `PartialPreemption` is on; R8 also writes the steps when `ElasticJobsViaWorkloadSlicesWithPartialReplicaScaleUp` is on.

## Preemption seam

R5 adds `Remaining` to `policy.Target` and the helpers below in `pkg/scheduler/preemption/policy/partial.go`. `Remaining` and `RemoveFrom`/`AddTo` match [kubernetes-sigs/kueue#17484](https://github.com/kubernetes-sigs/kueue/pull/17484).

```go
type Target struct {
	// existing fields unchanged

	// Remaining is the part of the workload that stays admitted when the target is shrunk
	// instead of evicted: the victim's workload.Info, under the same key, with each shrunk
	// PodSet's TotalRequests replaced by PodSetResources.ScaledTo(target count), keeping its
	// whole TAS usage. Nil for a whole eviction.
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

// SimulateUsageRemoval removes each target's FreedUsage from its ClusterQueue, skipping
// workloads whose usage the cycle already released, and returns the revert. With no
// Remaining set it does what Snapshot.SimulateWorkloadUsageRemoval does.
func SimulateUsageRemoval(snapshot *schdcache.Snapshot, targets []*Target) (revert func())

// EvictedWorkloads returns the workloads of the targets without Remaining, the only
// ones whose pods leave the scheduling simulator.
func EvictedWorkloads(targets []*Target) []*workload.Info
```

`preemption.PreemptedWorkloads` becomes `map[workload.Reference]*Target`, and `Targets()` replaces `Workloads()`, so a shrunk victim's `Remaining` reaches the scheduler's own checks. Every site that takes a victim out of the snapshot goes through the seam:

| # | Site | Change |
| :-: | :--- | :--- |
| 1 | `policy.YieldFromSnapshot` (all strategies) | `t.RemoveFrom(snapshot)` |
| 2 | `restoreSnapshot`, `fillBackWorkloads` (`preemption.go`) | `AddTo`/`RemoveFrom`; fill-back grows a shrunk target's `Remaining` back step by step while the preemptor still fits |
| 3 | the preemption oracle (`preemption_oracle.go`) | `SimulateUsageRemoval(snapshot, candidates)` |
| 4 | `fits` (`scheduler.go`) | `SimulateUsageRemoval` over `MergeWithTargets(newTargets).Targets()` |
| 5 | `simulateOtherPreemptions` (`scheduler.go`) | `SimulateRemoval`, and `SimulatePodRemoval` only for `EvictedWorkloads` |
| 6 | `nativePlanner.updateAssignmentForTAS` (`assignment/native/native.go`) | as site 5 |
| 7 | fair-sharing share and verify (`fair_strategy.go`, `fairsharing/target.go`) | unchanged: the fair-sharing and configurable strategies yield whole targets only, which a test asserts |
| 8 | 0005's topology retry (`topology_retry*.go`) | starts from a snapshot restored with `AddTo`; candidate usage comes from `FreedUsage()`, so a shrunk candidate frees quota only |
| 9 | `bookUsage` (`scheduler.go`), which calls `ReleaseWorkloadUsage` on a replaced slice | unchanged: `RemoveWorkload` and `AddWorkload` skip the usage of a released workload, and `Remaining` shares its key, so a replaced slice that is also a target frees nothing twice; `SimulateUsageRemoval` keeps the same rule |

With `PartialPreemption` off no target has `Remaining`, so every site behaves as upstream.

An in-flight partial victim, one whose reclaim target is still pending, is offered first, next to the evicted candidates, with `Remaining` set to the Info shrunk to its pending target. `splitEvicted` (`classical/candidate_generator.go`) and `buildBuckets` (`classical/cache_candidate_generator.go`) assume the evicted candidates form a prefix of the sorted list (`splitEvicted` finds its end with `sort.Search`), so in-flight victims enter through the evicted-first comparator in `policy/ordering.go`, sorted right after the evicted ones, not by appending to either group, so a later preemptor counts the quota that is already on its way out. When a shrunk target is not enough, R5 escalates it to a whole eviction by clearing `Remaining` on the same `Target`, never by adding a second `Target` for the same workload.

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

## Migration from p0.6.x

Patch releases up to p0.6.x gave every Ray worker group `minCount = minReplicas`. Where that `minCount` survives:

- **Non-elastic Workloads holding quota** keep it until the quota is released; R0 keeps them matching their jobs, and the job reconciler then replaces their PodSets with the job's.
- **Elastic Workloads without the partial scale-up annotation** drop it at their next slice: `ConstructWorkload` copies a predecessor's `minCount` forward only when `ElasticPartialScaleUpEnabled(job)` (`prepareWorkloadSliceForScaleUp`), which R0's `TestMinCountMigrationSliceChain` pins. A cluster that never resizes keeps its Workload, and its `minCount`, until it resizes or is recreated.
- **Elastic Workloads with the partial scale-up annotation** copy `min(minReplicas, count)` forward along the slice chain for as long as the chain lives. It is at most upstream's floor, so the only effect is that readmission may be partial down to `minReplicas`; recreating the cluster starts a clean chain. These clusters need `ElasticJobsViaWorkloadSlicesWithPartialReplicaScaleUp` anyway.

The [readme](../../readme.md#feature-gates) gives the exit condition for that gate and for R0.

## Acceptance tests

These scenarios and cases cover behavior the stack lost when the earlier partial preemption patches were removed, and cases the new patches must handle. Chainsaw cannot skip single steps, so a scenario whose steps need a later patch is split when its other steps pass on their own: those stay in the original scenario, and the rest move to a scenario with `spec.skip: true` and a comment naming the patch that runs it again; that patch removes the skip and rewrites the assertions shown. `distributed/10` was split into 10 and 12; `distributed/09` stays skipped whole: its cohort reclaim step needs the redesign, and its ScaleGate step cannot run without that step and asserts `replicas: 4`, which only the earlier patches' replica sync produced; its `maxReplicas: 8` is the static quota bound that `kuberay/03-scalegate-quota/03-borrowing-limit-clamping` covers. 12's last step asserts that the cluster re-expands to 4 workers after a spot interruption, which no component does once Kueue stops writing `replicas`; R6 rewrites it to the autoscaler's regrowth.

| Owner | Test | Must show |
| :-: | :--- | :--- |
| R5 | [`kueue/01-partial-preemption/01-collaborative-drain`](../../tests/scenarios/kueue/01-partial-preemption/01-collaborative-drain), [`kueue/01-partial-preemption/03-cohort-reclaim`](../../tests/scenarios/kueue/01-partial-preemption/03-cohort-reclaim) | the victim keeps `replicas`, its pods above the target are deleted and recreated gated, its `reclaimablePods` rise, and only then is the preemptor admitted |
| R5 | a victim whose shrink to its floor is not enough, replacing the removed `02-min-viable-guard` scenario | the victim is evicted whole and the preemptor admitted, the opposite of the removed scenario |
| R5 | [`distributed/05-spot-elastic-reexpansion`](../../tests/scenarios/distributed/05-spot-elastic-reexpansion), [`distributed/09-shared-kueue-fleet-fairness`](../../tests/scenarios/distributed/09-shared-kueue-fleet-fairness), [`distributed/12-interlink-cloudvm-partial-preemption`](../../tests/scenarios/distributed/12-interlink-cloudvm-partial-preemption) | as the first row, with re-expansion steps owned by R6 |
| R5 | unit cases from [#73](https://github.com/simonepri/elastic-kueue-kuberay-patches/pull/73) and its reviews | `[shrunk elastic, W]` found when the elastic victim comes first and shrinking alone is not enough; no whole eviction where a shrink suffices; a TAS shrink plan that the planner and `fits` both accept; multi-PodSet victims charged per PodSet; reclaimable pods and nil assignment counts counted as in `workload.Info`; the cached Workload never mutated; batch Jobs with `minCount` never shrunk; fair sharing returning vanilla's targets |
| R5 | an in-flight partial victim and a repeated preemption | the victim is offered first with its pending target as `Remaining`; escalation leaves one `Target` per workload; re-issuing the same target writes nothing and leaves no expectation pending |
| R3, R4, R5 | elastic RayJob and RayService victims | evicted whole, never given a floor or a target |
| R3 | stopper and release unit and envtest cases | whole replica groups deleted, cheapest deletion cost first; no quota released while a pod above the target runs; targets and `reclaimablePods` cleared when quota is released |
| R3 | autoscaler scales down after a reclaim | a victim of 8 shrunk to 4 and then scaled to 4 by the autoscaler is charged 4 pods once the reconcile converges, its target is 4 and its reclaimable count 0, and no webhook call is rejected |
| R3 | autoscaler scales down a partially admitted victim after a reclaim | a victim with spec 8, granted 6, target 4 and reclaimable 4 that the autoscaler lowers to 6 keeps spec 8 and is charged 4 pods; lowered to 5, it ends at spec 5, reclaimable 1, charged 4; no webhook call is rejected |
| R3, R5 | a chainsaw scenario with `enableInTreeAutoscaling: true` | the autoscaler does not undo the shrink, and the preemptor and victim never run over quota together; required before a deployment enables `PartialPreemption` |
| R6 | [`kueue/02-elastic-reexpansion/01-reexpansion`](../../tests/scenarios/kueue/02-elastic-reexpansion/01-reexpansion) | a probe regrows the cluster once the preemptor no longer needs the quota, without Kueue writing `replicas` |
| R6 | envtest specs from [#78](https://github.com/simonepri/elastic-kueue-kuberay-patches/pull/78) (pending scale-up, autoscaler scale-down) | a voluntary scale-down and a pending scale-up are never reverted; probe names never collide with an existing slice |
| R1 | [#78](https://github.com/simonepri/elastic-kueue-kuberay-patches/pull/78)'s `kueue/05-elastic-template-reapply` scenario and re-apply envtest spec | after a re-apply that replaces `workerGroupSpecs`, new and replacement workers are ungated |
| R2 | [`kueue/06-elastic-flavor-from-zero/01-scale-up-from-zero`](../../tests/scenarios/kueue/06-elastic-flavor-from-zero/01-scale-up-from-zero) | workers of a moved PodSet run on the new flavor, including when flavors share node label keys |
| R4, R8 | multi-host cases from [#73](https://github.com/simonepri/elastic-kueue-kuberay-patches/pull/73) | floors and grants in whole replicas; steps written with `PartialPreemption` off; a replacement slice always grows on rounded counts |
