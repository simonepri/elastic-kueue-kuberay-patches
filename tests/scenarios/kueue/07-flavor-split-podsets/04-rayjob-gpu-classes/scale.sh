#!/bin/sh
# Sets the worker replicas of flavor-split-job in namespace $NS to $1 and, for each <entry>=<n> argument after it,
# names the newest n ungated workers of that split entry in workersToDelete, as the Ray autoscaler does on a scale-down.
set -eu
job=flavor-split-job
replicas=$1
shift
delete=""
for arg in "$@"; do
  entry=${arg%%=*}
  n=${arg#*=}
  names=$(kubectl -n "$NS" get pods -l "ray.io/group=workers,kueue.x-k8s.io/podset=$entry" -o json |
    jq -r --argjson n "$n" '[.items[] | select((.spec.schedulingGates // []) == [] and .metadata.deletionTimestamp == null)]
      | sort_by(.metadata.creationTimestamp, .metadata.name) | reverse | .[:$n][] | .metadata.name')
  if [ "$(echo "$names" | grep -c .)" -ne "$n" ]; then
    echo "entry $entry has fewer than $n ungated workers" >&2
    exit 1
  fi
  delete="$delete $names"
done
list=$(printf '%s\n' $delete | jq -R 'select(. != "")' | jq -cs .)
if [ "$list" = "[]" ]; then
  kubectl -n "$NS" patch rayjob "$job" --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/rayClusterSpec/workerGroupSpecs/0/replicas\",\"value\":$replicas}]"
  cluster=$(kubectl -n "$NS" get rayjob "$job" -o jsonpath='{.status.rayClusterName}' 2>/dev/null || true)
  if [ -n "$cluster" ]; then
    kubectl -n "$NS" patch raycluster "$cluster" --type=json -p "[
      {\"op\":\"replace\",\"path\":\"/spec/workerGroupSpecs/0/replicas\",\"value\":$replicas}]" 2>/dev/null || true
  fi
else
  kubectl -n "$NS" patch rayjob "$job" --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/rayClusterSpec/workerGroupSpecs/0/replicas\",\"value\":$replicas},
    {\"op\":\"add\",\"path\":\"/spec/rayClusterSpec/workerGroupSpecs/0/scaleStrategy\",\"value\":{\"workersToDelete\":$list}}]"
  cluster=$(kubectl -n "$NS" get rayjob "$job" -o jsonpath='{.status.rayClusterName}' 2>/dev/null || true)
  if [ -n "$cluster" ]; then
    kubectl -n "$NS" patch raycluster "$cluster" --type=json -p "[
      {\"op\":\"replace\",\"path\":\"/spec/workerGroupSpecs/0/replicas\",\"value\":$replicas},
      {\"op\":\"add\",\"path\":\"/spec/workerGroupSpecs/0/scaleStrategy\",\"value\":{\"workersToDelete\":$list}}]" 2>/dev/null || true
  fi
fi
echo "Scaled $job to $replicas workers, deleting $list"
