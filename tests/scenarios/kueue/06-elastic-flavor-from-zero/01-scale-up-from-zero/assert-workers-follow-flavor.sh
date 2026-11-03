#!/bin/sh
# Verifies admitted worker counts and pod placement after growth from zero, with or without greedy flavor splitting.
set -eu
want=$1
args=$(kubectl -n kueue-system get deployment kueue-controller-manager -o json | jq -r '.spec.template.spec.containers[].args[]')
expected='workers=6@fz-remote'
if printf '%s' "$args" | grep -q 'ElasticJobsViaWorkloadSlicesFlavorSplit=true'; then
  expected='workers=3@fz-local workers--2=3@fz-remote'
fi
start=$(date +%s)
until got=$(kubectl -n "$NS" get workloads -o json | jq -r '[.items[] | select(.status.admission != null and all(.status.conditions[]?; .type != "Finished" or .status != "True"))
  | [.status.admission.podSetAssignments[] | select(.name != "head")]
  | select((map(.count) | add) == 6) | sort_by(.name) | map("\(.name)=\(.count)@\(.flavors.cpu)") | join(" ")] | .[]') && [ "$got" = "$expected" ]; do
  [ $(($(date +%s)-start)) -lt 90 ] || { echo "worker admission '$got', want '$expected'" >&2; exit 1; }
  sleep 1
done
selector=ray.io/cluster=from-zero-cluster,ray.io/group=workers
while :; do
  pods=$(kubectl -n "$NS" get pods -l "$selector" -o json | jq -c '[.items[] | select(.metadata.deletionTimestamp == null and (.spec.schedulingGates // []) == [])]')
  [ "$(printf '%s' "$pods" | jq length)" -eq "$want" ] && break
  [ $(($(date +%s)-start)) -lt 90 ] || { echo 'workers did not ungate' >&2; exit 1; }
  sleep 1
done
printf '%s' "$pods" | jq -e --arg split "$expected" 'all(.[];
  (if ($split | contains("fz-local")) and .metadata.labels["kueue.x-k8s.io/podset"] == "workers" then
    .spec.nodeSelector["example.com/class"] == "test" and .spec.nodeSelector["example.com/provider"] == null
   else .spec.nodeSelector["example.com/provider"] == "remote" and any(.spec.tolerations[]?; .key == "example.com/provider" and .value == "remote") end))' >/dev/null
echo "Worker admission and pod placement: $got"
