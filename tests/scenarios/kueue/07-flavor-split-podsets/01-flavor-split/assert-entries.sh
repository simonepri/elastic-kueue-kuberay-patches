#!/bin/sh
# Waits until the one admitted, unfinished Workload of flavor-split-cluster in namespace $NS has exactly the worker
# entries given as <entry>=<count>@<flavor> arguments (<entry>=0 for an empty one), with those spec counts and GPU
# flavors, and each entry runs that many ungated workers labeled with it and placed on its flavor; fails after
# WAIT_SECONDS (90 by default).
set -eu
cluster=flavor-split-cluster
want=$(printf '%s\n' "$@" | sort | tr '\n' ' ')
state() {
  wl=$(kubectl -n "$NS" get workloads -o json | jq -c '[.items[] | select(any(.metadata.ownerReferences[]?; .name == "'"$cluster"'"))
    | select(.status.admission != null and all(.status.conditions[]?; .type != "Finished" or .status != "True"))]')
  if [ "$(printf "%s" "$wl" | jq length)" -ne 1 ]; then
    echo "admitted=$(printf "%s" "$wl" | jq length)"
    return
  fi
  pods=$(kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster,ray.io/group=workers" -o json | jq -c '[.items[]
    | select((.spec.schedulingGates // []) == [] and .metadata.deletionTimestamp == null)]')
  printf "%s" "$wl" | jq -r --argjson pods "$pods" '.[0] as $w | $w.spec.podSets[] | select(.name != "head") | .name as $n
    | ($w.status.admission.podSetAssignments[] | select(.name == $n) | .flavors["nvidia.com/gpu"]) as $f
    | ([$pods[] | select(.metadata.labels["kueue.x-k8s.io/podset"] == $n and .spec.nodeSelector["instance-type"] == $f)] | length) as $running
    | if .count == 0 and $running == 0 then "\($n)=0" elif $running == .count then "\($n)=\(.count)@\($f)" else "\($n)=\(.count)@\($f)/running=\($running)" end' | sort | tr '\n' ' '
}
start=$(date +%s)
until got=$(state) && [ "$got" = "$want" ]; do
  if [ $(($(date +%s) - start)) -ge "${WAIT_SECONDS:-90}" ]; then
    echo "worker entries of $cluster are '$got', want '$want'" >&2
    kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster" -o custom-columns=NAME:.metadata.name,PODSET:.metadata.labels.kueue\\.x-k8s\\.io/podset,GATES:.spec.schedulingGates[*].name,FLAVOR:.spec.nodeSelector.instance-type >&2
    kubectl -n "$NS" get workloads -o yaml >&2
    exit 1
  fi
  sleep 1
done
echo "Worker entries of $cluster: $got"
