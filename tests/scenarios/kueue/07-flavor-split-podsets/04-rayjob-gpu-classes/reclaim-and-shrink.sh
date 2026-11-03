#!/bin/sh
# Reclaims only the RayJob's first flavor, verifies surviving pods and regrowth, then shrinks and merges entries.
set -eu
args=$(kubectl -n kueue-system get deployment kueue-controller-manager -o json | jq -r '.spec.template.spec.containers[].args[]')
if printf '%s' "$args" | grep -q 'PartialPreemption=true'; then
  # The initial fill was atomic. Opt in to reclaim only after proving that placement.
  kubectl -n "$NS" annotate rayjob flavor-split-job kueue.x-k8s.io/elastic-job-scale-up-strategy=partial
  kubectl -n "$NS" patch rayjob flavor-split-job --type=json -p '[{"op":"add","path":"/spec/rayClusterSpec/workerGroupSpecs/0/minReplicas","value":2}]'
  start=$(date +%s)
  until kubectl -n "$NS" get workloads -o json | jq -e 'any(.items[]; .status.admission != null and .metadata.annotations["kueue.x-k8s.io/reclaim-min-counts"] == "workers=2,workers--2=0")' >/dev/null; do
    [ $(($(date +%s)-start)) -lt 90 ] || { echo 'RayJob reclaim floor not refreshed' >&2; exit 1; }
    sleep 1
  done
  survivors=$(kubectl -n "$NS" get pods -l 'ray.io/group=workers,kueue.x-k8s.io/podset=workers--2' -o json | jq -c '[.items[] | select((.spec.schedulingGates // []) == [] and .metadata.deletionTimestamp == null) | .metadata.uid] | sort')
  head=$(kubectl -n "$NS" get pods -l ray.io/node-type=head -o json | jq -r '.items[0].metadata.uid')
  kubectl -n "$NS" apply -f 02-preemptor-job.yaml
  start=$(date +%s)
  until kubectl -n "$NS" get workloads -o json | jq -e 'any(.items[]; any(.metadata.ownerReferences[]?; .name == "flavor-split-preemptor") and .status.admission != null)' >/dev/null; do
    [ $(($(date +%s)-start)) -lt 90 ] || { echo 'preemptor not admitted' >&2; exit 1; }
    sleep 1
  done
  ./assert-entries.sh workers=2@reserved-gpu workers--2=4@spot-gpu workers--3=4@spot-gpu
  after=$(kubectl -n "$NS" get pods -l 'ray.io/group=workers,kueue.x-k8s.io/podset=workers--2' -o json | jq -c '[.items[] | select((.spec.schedulingGates // []) == [] and .metadata.deletionTimestamp == null) | .metadata.uid] | sort')
  [ "$survivors" = "$after" ] || { echo 'reclaim replaced pods on the second flavor' >&2; exit 1; }
  [ "$head" = "$(kubectl -n "$NS" get pods -l ray.io/node-type=head -o json | jq -r '.items[0].metadata.uid')" ]
  kubectl -n "$NS" get rayjob flavor-split-job -o json | jq -e '.spec.suspend != true and .status.jobDeploymentStatus != "Failed"' >/dev/null
  cluster=$(kubectl -n "$NS" get rayjob flavor-split-job -o jsonpath='{.status.rayClusterName}')
  kubectl -n "$NS" get raycluster "$cluster" -o json | jq -e '.spec.suspend != true' >/dev/null
  ./scale.sh 2 workers--3=4 workers--2=4
  ./assert-entries.sh workers=2@reserved-gpu workers--2=0 workers--3=0
  kubectl -n "$NS" delete job flavor-split-preemptor --wait=true
else
  ./scale.sh 4 workers--2=4 workers=2
  ./assert-entries.sh workers=4@reserved-gpu workers--2=0
fi
./scale.sh 6
./assert-entries.sh workers=6@reserved-gpu
./assert-head.sh on-demand
