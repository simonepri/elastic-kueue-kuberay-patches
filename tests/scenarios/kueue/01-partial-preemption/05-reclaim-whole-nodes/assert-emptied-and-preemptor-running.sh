#!/bin/bash
set -eu
NS="${NS:-default}"
timeout=90
start=$(date +%s)

while true; do
  ./fake-kubelet.sh once || true

  # Check preemptor pod
  preemptor_node=$(kubectl -n "$NS" get pods -l "job-name=preemptor-job" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
  preemptor_phase=$(kubectl -n "$NS" get pods -l "job-name=preemptor-job" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)

  pods_a=$(kubectl -n "$NS" get pods -l "ray.io/group=workers" --field-selector spec.nodeName=fake-gpu-node-a --no-headers 2>/dev/null | grep -v Terminating | wc -l | tr -d ' ')
  pods_b=$(kubectl -n "$NS" get pods -l "ray.io/group=workers" --field-selector spec.nodeName=fake-gpu-node-b --no-headers 2>/dev/null | grep -v Terminating | wc -l | tr -d ' ')

  # One node must be completely emptied (0 workers), other must have 4 workers
  # Preemptor must be scheduled on the emptied node and Running
  if { [ "$pods_a" -eq 0 ] && [ "$pods_b" -eq 4 ] && [ "$preemptor_node" = "fake-gpu-node-a" ]; } || \
     { [ "$pods_b" -eq 0 ] && [ "$pods_a" -eq 4 ] && [ "$preemptor_node" = "fake-gpu-node-b" ]; }; then
    if [ "$preemptor_phase" = "Running" ]; then
      echo "Whole-node reclaim succeeded!"
      echo "Workers remaining: node-a=$pods_a, node-b=$pods_b"
      echo "Preemptor scheduled on $preemptor_node with phase $preemptor_phase"
      exit 0
    fi
  fi

  if [ $(($(date +%s) - start)) -ge "$timeout" ]; then
    echo "Timed out waiting for whole-node reclaim." >&2
    echo "Workers remaining: node-a=$pods_a, node-b=$pods_b" >&2
    echo "Preemptor: node=$preemptor_node, phase=$preemptor_phase" >&2
    kubectl -n "$NS" get pods -o wide >&2
    kubectl -n "$NS" get events --sort-by=.metadata.creationTimestamp >&2
    exit 1
  fi
  sleep 1
done
