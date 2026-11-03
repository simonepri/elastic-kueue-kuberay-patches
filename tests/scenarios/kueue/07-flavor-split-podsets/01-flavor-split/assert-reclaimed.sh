#!/bin/sh
# Waits until the lender's reclaim of flavor-a has left flavor-split-cluster in namespace $NS with $1 ungated workers in
# entry "workers", $2 in "workers--2" and $3 gated (either "-" for any number), the cluster unsuspended, and the lender's
# job admitted.
set -eu
cluster=flavor-split-cluster
state() {
  pods=$(kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster,ray.io/group=workers" -o json)
  ungated() {
    printf "%s" "$pods" | jq --arg e "$1" '[.items[] | select(.metadata.labels["kueue.x-k8s.io/podset"] == $e
      and (.spec.schedulingGates // []) == [] and .metadata.deletionTimestamp == null)] | length'
  }
  gated=$(printf "%s" "$pods" | jq '[.items[] | select((.spec.schedulingGates // []) != [])] | length')
  suspended=$(kubectl -n "$NS" get raycluster "$cluster" -o jsonpath='{.spec.suspend}')
  lender=$(kubectl -n "$NS" get workloads -o json | jq -r '[.items[] | select(any(.metadata.ownerReferences[]?; .name == "flavor-split-lender-job"))
    | select(.status.admission != null)] | length')
  split=$(ungated workers--2)
  [ "$want_split" = "-" ] && split=-
  [ "$want_gated" = "-" ] && gated=-
  echo "workers=$(ungated workers) workers--2=$split gated=$gated suspended=${suspended:-false} lender-admitted=$lender"
}
want_split=$2
want_gated=$3
want="workers=$1 workers--2=$2 gated=$3 suspended=false lender-admitted=1"
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
