#!/bin/sh
# Waits until flavor-split-cluster in namespace $NS has no pods and no unfinished Workload left; fails after WAIT_SECONDS (90 by default).
set -eu
cluster=flavor-split-cluster
state() {
  pods=$(kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  active=$(kubectl -n "$NS" get workloads -o json | jq '[.items[] | select(any(.metadata.ownerReferences[]?; .name == "'"$cluster"'"))
    | select(all(.status.conditions[]?; .type != "Finished" or .status != "True"))] | length')
  echo "pods=$pods active-workloads=$active"
}
want="pods=0 active-workloads=0"
start=$(date +%s)
until got=$(state) && [ "$got" = "$want" ]; do
  if [ $(($(date +%s) - start)) -ge "${WAIT_SECONDS:-90}" ]; then
    echo "after deleting $cluster: '$got', want '$want'" >&2
    exit 1
  fi
  sleep 1
done
echo "Finished $cluster: $got"
