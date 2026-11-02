#!/bin/sh
# Scenario 3 (LIFO shrink): scale from 12 to 10 reduces workers--2 to 2 and leaves workers at 8.
set -eu

if [ -z "${TEST_FLAVOR_SPLIT:-}" ]; then
  echo "Skipping assert-lifo-shrink: TEST_FLAVOR_SPLIT is not set"
  exit 0
fi

NS="${NS:-default}"
cluster="flavor-split-cluster"
timeout="${WAIT_SECONDS:-30}"
start=$(date +%s)

echo "Waiting for LIFO shrink to 10 workers on $cluster..."

while true; do
  active_wl=$(kubectl -n "$NS" get workloads -o json | jq -r '[.items[] | select(.metadata.ownerReferences[]?.name == "'"$cluster"'" and all(.status.conditions[]?; .type != "Finished" or .status != "True") and (.status.admission != null))]')

  count_fa=$(echo "$active_wl" | jq -r '.[0].status.admission.podSetAssignments[] | select(.name == "workers") | .count // 0')
  count_fb=$(echo "$active_wl" | jq -r '.[0].status.admission.podSetAssignments[] | select(.name == "workers--2") | .count // 0')

  if [ "$count_fa" -eq 8 ] && [ "$count_fb" -eq 2 ]; then
    echo "SUCCESS: Scenario 3 LIFO shrink verified!"
    echo "- workers (flavor-a): 8"
    echo "- workers--2 (flavor-b): 2"
    exit 0
  fi

  if [ $(($(date +%s) - start)) -ge "$timeout" ]; then
    echo "FAILURE: LIFO shrink assertion timed out after ${timeout}s" >&2
    echo "Got workers=$count_fa, workers--2=$count_fb; want workers=8, workers--2=2" >&2
    exit 1
  fi
  sleep 1
done
