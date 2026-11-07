#!/bin/bash
# No kubelet runs on the simulated nodes. After the real scheduler's binding
# assertions, simulate completion and release quota before Chainsaw deletes queues.
set -euo pipefail
. ./bounded-waits.sh
job=$1
pods=$(kubectl -n "$NS" get pods -l "job-name=$job" -o json | jq -r '.items[].metadata.name')
for pod in $pods; do
  kubectl -n "$NS" patch pod "$pod" --subresource=status --type=merge \
    -p '{"status":{"phase":"Succeeded"}}' >/dev/null
done
if [ -n "$pods" ]; then
  kubectl -n "$NS" wait "job/$job" --for=condition=Complete --timeout=20s
fi
workloads=$(kubectl -n "$NS" get workloads -o json | jq -r --arg job "$job" \
  '.items[] | select(any(.metadata.ownerReferences[]?; .kind == "Job" and .name == $job)) | .metadata.name')
kubectl -n "$NS" delete job "$job" --ignore-not-found --wait=false >/dev/null
for wl in $workloads; do
  kubectl -n "$NS" delete workload "$wl" --ignore-not-found --wait=true --timeout=30s
done
kubectl -n "$NS" delete pods -l "job-name=$job" --ignore-not-found --force --grace-period=0 --wait=false >/dev/null
