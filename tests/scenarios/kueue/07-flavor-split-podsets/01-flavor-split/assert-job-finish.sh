#!/bin/sh
# Scenario 5 (Job finish): the Workload and all pods finish cleanly.
set -eu

if [ -z "${TEST_FLAVOR_SPLIT:-}" ]; then
  echo "Skipping assert-job-finish: TEST_FLAVOR_SPLIT is not set"
  exit 0
fi

NS="${NS:-default}"
cluster="flavor-split-cluster"
timeout="${WAIT_SECONDS:-30}"
start=$(date +%s)

echo "Waiting for job finish and clean teardown of $cluster..."

while true; do
  pods_count=$(kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster" --no-headers 2>/dev/null | wc -l)
  active_wl=$(kubectl -n "$NS" get workloads -o json | jq -r '[.items[] | select(.metadata.ownerReferences[]?.name == "'"$cluster"'" and all(.status.conditions[]?; .type != "Finished" or .status != "True"))]' | jq 'length')

  if [ "$pods_count" -eq 0 ] && [ "$active_wl" -eq 0 ]; then
    echo "SUCCESS: Scenario 5 Job finish verified!"
    echo "- Pods remaining: 0"
    echo "- Active Workloads remaining: 0"
    exit 0
  fi

  if [ $(($(date +%s) - start)) -ge "$timeout" ]; then
    echo "FAILURE: Job finish assertion timed out after ${timeout}s" >&2
    echo "Remaining pods: $pods_count, Active workloads: $active_wl" >&2
    exit 1
  fi
  sleep 1
done
