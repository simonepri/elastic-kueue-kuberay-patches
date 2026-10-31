#!/usr/bin/env bash
# Checks that a fixed-size RayCluster resized past its admission was requeued: its Workload asks for the new
# worker count without an admission, and none of its worker pods remain.
# Usage: NS=<namespace> assert-requeued.sh <raycluster> <podset> <workers>
set -euo pipefail
cluster=$1
podset=$2
want=$3

for _ in $(seq 1 45); do
  workloads=$(kubectl get workloads -n "$NS" -o json | jq --arg c "$cluster" '
    [.items[] | select(any(.metadata.ownerReferences[]?; .name == $c))]')
  requested=$(jq --arg p "$podset" '[.[].spec.podSets[] | select(.name == $p) | .count] | max // 0' <<<"$workloads")
  admitted=$(jq '[.[] | select(.status.admission != null)] | length' <<<"$workloads")
  total=$(kubectl get pods -n "$NS" -l "ray.io/cluster=$cluster,ray.io/node-type=worker" -o json | jq '.items | length')
  echo "cluster=$cluster podset=$podset requested=$requested admitted_workloads=$admitted worker_pods=$total"
  if [ "$requested" -eq "$want" ] && [ "$admitted" -eq 0 ] && [ "$total" -eq 0 ]; then
    exit 0
  fi
  sleep 2
done
echo "the cluster was not requeued at $want workers with no worker pods left" >&2
kubectl get pods -n "$NS" -l "ray.io/cluster=$cluster" -o wide >&2 || true
exit 1
