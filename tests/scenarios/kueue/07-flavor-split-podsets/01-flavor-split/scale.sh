#!/bin/sh
# Sets the worker replicas of flavor-split-cluster in namespace $NS to $1 and, for each <entry>=<n> argument after it,
# names the newest n ungated workers of that split entry in workersToDelete, as the Ray autoscaler does on a scale-down.
set -eu
cluster=flavor-split-cluster
replicas=$1
shift
delete=""
for arg in "$@"; do
  entry=${arg%%=*}
  n=${arg#*=}
  names=$(kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster,kueue.x-k8s.io/podset=$entry" -o json |
    jq -r --argjson n "$n" '[.items[] | select((.spec.schedulingGates // []) == [] and .metadata.deletionTimestamp == null)]
      | sort_by(.metadata.creationTimestamp, .metadata.name) | reverse | .[:$n][] | .metadata.name')
  if [ "$(echo "$names" | grep -c .)" -ne "$n" ]; then
    echo "entry $entry has fewer than $n ungated workers" >&2
    exit 1
  fi
  delete="$delete $names"
done
list=$(printf '%s\n' $delete | jq -R 'select(. != "")' | jq -cs .)
kubectl -n "$NS" patch raycluster "$cluster" --type=json -p "[
  {\"op\":\"replace\",\"path\":\"/spec/workerGroupSpecs/0/replicas\",\"value\":$replicas},
  {\"op\":\"add\",\"path\":\"/spec/workerGroupSpecs/0/scaleStrategy\",\"value\":{\"workersToDelete\":$list}}]"
echo "Scaled $cluster to $replicas workers, deleting $list"
