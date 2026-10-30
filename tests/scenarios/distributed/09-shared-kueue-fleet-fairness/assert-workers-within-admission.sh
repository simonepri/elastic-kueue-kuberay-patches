#!/usr/bin/env bash
# Checks that a resized elastic RayCluster runs exactly the worker pods its admitted Workload slice grants: never more.
# Usage: NS=<namespace> assert-workers-within-admission.sh <raycluster> <podset>
set -euo pipefail
cluster=$1
podset=$2
gate=kueue.x-k8s.io/elastic-job

# granted prints the workers the admitted, unfinished Workload slice of the cluster grants the pod set.
granted() {
  kubectl get workloads -n "$NS" -o json | jq --arg c "$cluster" --arg p "$podset" '
    [.items[]
     | select(any(.metadata.ownerReferences[]?; .name == $c))
     | select(.status.admission != null)
     | select(all((.status.conditions // [])[]; .type != "Finished" or .status != "True"))
     | .status.admission.podSetAssignments[] | select(.name == $p) | .count]
    | max // 0'
}

# workers prints the cluster's live worker pods as JSON.
workers() {
  kubectl get pods -n "$NS" -l "ray.io/cluster=$cluster,ray.io/node-type=worker" -o json |
    jq '[.items[] | select(.metadata.deletionTimestamp == null)]'
}

# dump prints every pod in the namespace with the labels, gates, and phase the check reads.
dump() {
  kubectl get pods -n "$NS" -o json | jq -r '.items[] |
    "\(.metadata.name) labels=\(.metadata.labels // {} | tojson) gates=\([.spec.schedulingGates[]?.name] | join(",")) phase=\(.status.phase) node=\(.spec.nodeName // "")"'
}

echo "pods in $NS:"
dump
stable=0
last=""
for _ in $(seq 1 45); do
  want=$(granted)
  pods=$(workers)
  total=$(jq 'length' <<<"$pods")
  ungated=$(jq --arg g "$gate" '[.[] | select(all((.spec.schedulingGates // [])[]; .name != $g))] | length' <<<"$pods")
  running=$(jq '[.[] | select(.status.phase == "Running")] | length' <<<"$pods")
  echo "cluster=$cluster podset=$podset granted=$want total=$total ungated=$ungated running=$running"
  if [ "$ungated" -gt "$want" ]; then
    echo "more worker pods are ungated than the admitted slice grants" >&2
    dump
    exit 1
  fi
  state="$want/$ungated"
  if [ "$ungated" -ge 1 ] && [ "$ungated" -eq "$want" ] && [ "$state" = "$last" ]; then
    stable=$((stable + 1))
    if [ "$stable" -ge 3 ]; then
      exit 0
    fi
  else
    stable=0
  fi
  last=$state
  sleep 2
done
echo "the ungated workers did not settle at the granted count" >&2
dump
exit 1
