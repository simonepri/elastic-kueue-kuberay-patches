#!/bin/sh
# Waits until worker group $2 of RayCluster $1 in namespace $NS has $3 ungated Pods that have not terminated and, when
# $4 is given, $4 Pods that Kueue keeps gated, such as the ones KubeRay recreates above a reclaim target; it fails after
# WAIT_SECONDS (55 by default).
set -eu
cluster=$1
group=$2
want_ungated=$3
want_gated=${4-}
pods() {
  kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster,ray.io/group=$group" --no-headers \
    -o custom-columns=PHASE:.status.phase,DELETING:.metadata.deletionTimestamp,GATES:.spec.schedulingGates[*].name
}
counts() {
  pods | awk '$1 != "Succeeded" && $1 != "Failed" { if ($3 == "<none>") ungated++; else if ($2 == "<none>") gated++ }
    END { printf "%d %d\n", ungated, gated }'
}
start=$(date +%s)
until set -- $(counts) && [ "$1" -eq "$want_ungated" ] && { [ -z "$want_gated" ] || [ "$2" -eq "$want_gated" ]; }; do
  if [ $(($(date +%s) - start)) -ge "${WAIT_SECONDS:-55}" ]; then
    echo "worker group $group of RayCluster $cluster has $1 ungated and $2 gated Pods, want $want_ungated and ${want_gated:-any}" >&2
    pods >&2
    kubectl -n "$NS" get workloads -o yaml >&2
    exit 1
  fi
  sleep 1
done
echo "Worker group $group of RayCluster $cluster has $1 ungated and $2 gated Pods"
