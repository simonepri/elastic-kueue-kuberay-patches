#!/bin/sh
# Scenario 4 (Merge-back): shrink to 8 drops workers--2 from the next slice.
set -eu

if [ -z "${TEST_FLAVOR_SPLIT:-}" ]; then
  echo "Skipping assert-merge-back: TEST_FLAVOR_SPLIT is not set"
  exit 0
fi

NS="${NS:-default}"
cluster="flavor-split-cluster"
timeout="${WAIT_SECONDS:-30}"
start=$(date +%s)

echo "Waiting for merge-back to 8 workers on $cluster..."

while true; do
  active_wl=$(kubectl -n "$NS" get workloads -o json | jq -r '[.items[] | select(.metadata.ownerReferences[]?.name == "'"$cluster"'" and all(.status.conditions[]?; .type != "Finished" or .status != "True") and (.status.admission != null))]')

  count_fa=$(echo "$active_wl" | jq -r '.[0].status.admission.podSetAssignments[] | select(.name == "workers") | .count // 0')
  has_fb=$(echo "$active_wl" | jq -r '.[0].status.admission.podSetAssignments[] | select(.name == "workers--2") | .name // ""')

  if [ "$count_fa" -eq 8 ] && [ -z "$has_fb" ]; then
    echo "SUCCESS: Scenario 4 Merge-back verified!"
    echo "- workers (flavor-a): 8"
    echo "- workers--2: dropped from slice"
    exit 0
  fi

  if [ $(($(date +%s) - start)) -ge "$timeout" ]; then
    echo "FAILURE: Merge-back assertion timed out after ${timeout}s" >&2
    echo "Got workers=$count_fa, workers--2=$has_fb; want workers=8, workers--2 absent" >&2
    exit 1
  fi
  sleep 1
done
