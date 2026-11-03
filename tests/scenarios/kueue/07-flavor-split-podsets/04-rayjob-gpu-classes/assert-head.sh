#!/bin/sh
# Waits until the head pod set of flavor-split-job in namespace $NS has the flavor specified in $1 (default on-demand).
set -eu
job=flavor-split-job
want_flavor=${1:-on-demand}
state() {
  wl=$(kubectl -n "$NS" get workloads -o json | jq -c '[.items[] | select(any(.metadata.ownerReferences[]?; .name == "'"$job"'"))
    | select(.status.admission != null and all(.status.conditions[]?; .type != "Finished" or .status != "True"))]')
  if [ "$(printf "%s" "$wl" | jq length)" -ne 1 ]; then
    echo "admitted=$(printf "%s" "$wl" | jq length)"
    return
  fi
  printf "%s" "$wl" | jq -r ' .[0].status.admission.podSetAssignments[] | select(.name == "head") | .flavors.cpu'
}
start=$(date +%s)
until got=$(state) && [ "$got" = "$want_flavor" ]; do
  if [ $(($(date +%s) - start)) -ge "${WAIT_SECONDS:-90}" ]; then
    echo "head flavor of $job is '$got', want '$want_flavor'" >&2
    exit 1
  fi
  sleep 1
done
echo "Head flavor of $job: $got"
