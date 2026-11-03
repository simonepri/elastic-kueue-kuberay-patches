#!/bin/bash
set -eu
NS="${NS:-default}"
timeout=120
start=$(date +%s)

scale_to() {
  local target_replicas=$1
  local min_replicas=${2:-$target_replicas}

  echo "Scaling workers to replicas=$target_replicas, minReplicas=$min_replicas..."
  kubectl -n "$NS" patch rayjob elastic-rayjob --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/rayClusterSpec/workerGroupSpecs/0/replicas\",\"value\":$target_replicas},
    {\"op\":\"replace\",\"path\":\"/spec/rayClusterSpec/workerGroupSpecs/0/minReplicas\",\"value\":$min_replicas}]"
  cluster=$(kubectl -n "$NS" get rayjob elastic-rayjob -o jsonpath='{.status.rayClusterName}' 2>/dev/null || true)
  if [ -n "$cluster" ]; then
    kubectl -n "$NS" patch raycluster "$cluster" --type=json -p "[
      {\"op\":\"replace\",\"path\":\"/spec/workerGroupSpecs/0/replicas\",\"value\":$target_replicas},
      {\"op\":\"replace\",\"path\":\"/spec/workerGroupSpecs/0/minReplicas\",\"value\":$min_replicas}]" 2>/dev/null || true
  fi
}

wait_for_workers() {
  local want_a=$1
  local want_b=$2
  echo "Waiting for worker distribution: node-a=$want_a, node-b=$want_b..."

  while true; do
    ./fake-kubelet.sh once || true

    pods_a=$(kubectl -n "$NS" get pods -l "ray.io/group=workers" --field-selector spec.nodeName=fake-gpu-node-a --no-headers 2>/dev/null | grep -v Terminating | wc -l | tr -d ' ')
    pods_b=$(kubectl -n "$NS" get pods -l "ray.io/group=workers" --field-selector spec.nodeName=fake-gpu-node-b --no-headers 2>/dev/null | grep -v Terminating | wc -l | tr -d ' ')

    if [ "$pods_a" -eq "$want_a" ] && [ "$pods_b" -eq "$want_b" ]; then
      echo "Reached distribution: node-a=$pods_a, node-b=$pods_b"
      return 0
    fi

    if [ $(($(date +%s) - start)) -ge "$timeout" ]; then
      echo "Timed out waiting for worker distribution $want_a+$want_b. Current: node-a=$pods_a, node-b=$pods_b" >&2
      kubectl -n "$NS" get pods -o wide >&2
      exit 1
    fi
    sleep 1
  done
}

# 1. Initial scale: 2 workers (1 on node-a, 1 on node-b)
wait_for_workers 1 1
sleep 1

# 2. Scale 2 more -> 4 workers (2 on node-a, 2 on node-b)
scale_to 4 2
wait_for_workers 2 2
sleep 1

# 3. Scale 2 more -> 6 workers (3 on node-a, 3 on node-b)
scale_to 6 2
wait_for_workers 3 3
sleep 1

# 4. Scale 2 more -> 8 workers with floor=4 (4 on node-a, 4 on node-b)
scale_to 8 4
wait_for_workers 4 4

echo "Successfully distributed 8 workers across nodes interleaved: 4 on node-a, 4 on node-b"
exit 0
