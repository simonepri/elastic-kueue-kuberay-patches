#!/bin/sh
# Waits until Kueue admits the Workload of Job $4 in namespace $NS, and fails if it is admitted while worker group $2
# of RayCluster $1 still has more than $3 ungated Pods that have not terminated, terminating ones included, or when it
# is not admitted within WAIT_SECONDS (85 by default).
set -eu
cluster=$1
group=$2
target=$3
job=$4
admitted() {
  kubectl -n "$NS" get workloads --no-headers \
    -o custom-columns=OWNER:.metadata.ownerReferences[0].name,QUEUE:.status.admission.clusterQueue |
    awk -v job="$job" '$1 == job && $2 != "<none>"' | wc -l
}
holding() {
  kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster,ray.io/group=$group" --no-headers \
    -o custom-columns=PHASE:.status.phase,GATES:.spec.schedulingGates[*].name |
    awk '$2 == "<none>" && $1 != "Succeeded" && $1 != "Failed"' | wc -l
}
# The Pods are read after the admission, so a count above the target means both held at once.
start=$(date +%s)
until [ "$(admitted)" -gt 0 ]; do
  if [ $(($(date +%s) - start)) -ge "${WAIT_SECONDS:-85}" ]; then
    echo "Job $job was not admitted within ${WAIT_SECONDS:-85}s" >&2
    kubectl -n "$NS" get workloads -o yaml >&2
    kubectl -n "$NS" get pods -o wide >&2
    exit 1
  fi
  sleep 0.2
done
count=$(holding)
if [ "$count" -gt "$target" ]; then
  echo "Job $job was admitted while worker group $group of RayCluster $cluster held $count Pods, above its reclaim target $target" >&2
  kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster" -o wide >&2
  exit 1
fi
echo "Job $job was admitted with worker group $group of RayCluster $cluster holding $count Pods"
