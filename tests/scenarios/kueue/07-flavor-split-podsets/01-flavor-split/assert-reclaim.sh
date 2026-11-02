#!/bin/sh
# Scenario 2 (Reclaim): higher-priority workload claims flavor-a.
# Only the 8 flavor-a pods are removed; the 4 flavor-b pods keep running; the RayCluster is not suspended.
set -eu

if [ -z "${TEST_FLAVOR_SPLIT:-}" ]; then
  echo "Skipping assert-reclaim: TEST_FLAVOR_SPLIT is not set"
  exit 0
fi

NS="${NS:-default}"
cluster="flavor-split-cluster"
timeout="${WAIT_SECONDS:-30}"
start=$(date +%s)

echo "Waiting for reclaim of flavor-a on $cluster..."

while true; do
  pods_fa=$(kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster,kueue.x-k8s.io/podset=workers" --no-headers 2>/dev/null | awk '$1 != "Succeeded" && $1 != "Failed" && $2 == "<none>" {print $1}' | wc -l)
  pods_fb=$(kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster,kueue.x-k8s.io/podset=workers--2" --no-headers 2>/dev/null | awk '$1 != "Succeeded" && $1 != "Failed" && $2 == "<none>" {print $1}' | wc -l)

  is_suspended=$(kubectl -n "$NS" get raycluster "$cluster" -o jsonpath='{.spec.suspend}' 2>/dev/null || echo "")
  head_running=$(kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster,ray.io/node-type=head" --no-headers 2>/dev/null | awk '$3 != "<none>" {print $1}' | wc -l)

  if [ "$pods_fa" -eq 0 ] && [ "$pods_fb" -eq 4 ] && [ "$is_suspended" != "true" ] && [ "$head_running" -ge 1 ]; then
    echo "SUCCESS: Scenario 2 Reclaim verified!"
    echo "- flavor-a pods removed: 8"
    echo "- flavor-b pods running: 4"
    echo "- RayCluster suspended: false"
    exit 0
  fi

  if [ $(($(date +%s) - start)) -ge "$timeout" ]; then
    echo "FAILURE: Reclaim assertion timed out after ${timeout}s" >&2
    echo "flavor-a pods: $pods_fa (want 0), flavor-b pods: $pods_fb (want 4), suspended: $is_suspended" >&2
    exit 1
  fi
  sleep 1
done
