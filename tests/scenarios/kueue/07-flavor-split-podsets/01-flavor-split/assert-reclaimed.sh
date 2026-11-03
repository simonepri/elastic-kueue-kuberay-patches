#!/bin/sh
# Waits until the lender's reclaim of flavor-a has stopped every worker of entry "workers" of flavor-split-cluster in
# namespace $NS, left the 4 workers of "workers--2" running and the cluster unsuspended, and admitted the lender's job.
set -eu
cluster=flavor-split-cluster
state() {
  pods=$(kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster,ray.io/group=workers" -o json)
  ungated() {
    echo "$pods" | jq --arg e "$1" '[.items[] | select(.metadata.labels["kueue.x-k8s.io/podset"] == $e
      and (.spec.schedulingGates // []) == [] and .metadata.deletionTimestamp == null)] | length'
  }
  gated=$(echo "$pods" | jq '[.items[] | select((.spec.schedulingGates // []) != [])] | length')
  suspended=$(kubectl -n "$NS" get raycluster "$cluster" -o jsonpath='{.spec.suspend}')
  lender=$(kubectl -n "$NS" get workloads -o json | jq -r '[.items[] | select(any(.metadata.ownerReferences[]?; .name == "flavor-split-lender-job"))
    | select(.status.admission != null)] | length')
  echo "workers=$(ungated workers) workers--2=$(ungated workers--2) gated=$gated suspended=${suspended:-false} lender-admitted=$lender"
}
want="workers=0 workers--2=4 gated=8 suspended=false lender-admitted=1"
start=$(date +%s)
until got=$(state) && [ "$got" = "$want" ]; do
  if [ $(($(date +%s) - start)) -ge "${WAIT_SECONDS:-90}" ]; then
    echo "after the reclaim: '$got', want '$want'" >&2
    kubectl -n "$NS" get workloads -o yaml >&2
    exit 1
  fi
  sleep 1
done
echo "Reclaim of flavor-a: $got"
