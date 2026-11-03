#!/bin/bash
set -eu
NS="${NS:-default}"
timeout=60
start=$(date +%s)

while true; do
  ./fake-kubelet.sh once || true

  pods_a=$(kubectl -n "$NS" get pods -l "ray.io/group=workers" --field-selector spec.nodeName=fake-gpu-node-a --no-headers 2>/dev/null | grep -v Terminating | wc -l | tr -d ' ')
  pods_b=$(kubectl -n "$NS" get pods -l "ray.io/group=workers" --field-selector spec.nodeName=fake-gpu-node-b --no-headers 2>/dev/null | grep -v Terminating | wc -l | tr -d ' ')

  if [ "$pods_a" -eq 4 ] && [ "$pods_b" -eq 4 ]; then
    echo "Successfully distributed 8 workers across nodes: 4 on node-a, 4 on node-b"
    exit 0
  fi

  if [ $(($(date +%s) - start)) -ge "$timeout" ]; then
    echo "Timed out waiting for 4+4 workers distribution. Node-a: $pods_a, Node-b: $pods_b" >&2
    kubectl -n "$NS" get pods -o wide >&2
    exit 1
  fi
  sleep 1
done
