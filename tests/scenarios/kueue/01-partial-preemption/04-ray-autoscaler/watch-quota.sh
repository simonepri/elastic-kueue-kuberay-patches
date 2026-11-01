#!/bin/sh
# Polls namespace $NS until the shell condition $1 holds, or for $2 seconds when $2 is given, and fails as soon as the
# autoscaled workers and the preemptor pods that hold resources, gated pods excluded, exceed the 4 that the
# ClusterQueue's CPU quota fits beside the head. Without $2, it fails after WATCH_SECONDS (280 by default).
# NOTE(simonepri): the ClusterQueue's reservation is not polled: while a replacement slice is admitted, Kueue keeps the
# slice it replaces in the ClusterQueue until it marks it finished, so the reported total briefly counts both. The
# assert files check the reservation once the slices settle.
set -eu
condition=$1
duration=${2-}
quota_slots=4
# holding counts the pods that hold node resources: scheduled or schedulable, not terminated, terminating ones included.
holding() {
  kubectl -n "$NS" get pods --no-headers \
    -o custom-columns='PHASE:.status.phase,GATES:.spec.schedulingGates[*].name,GROUP:.metadata.labels.ray\.io/group,JOB:.metadata.labels.job-name' |
    awk '$1 != "Succeeded" && $1 != "Failed" && $2 == "<none>" && ($3 == "workers" || $4 ~ /^preemptor-/)' | wc -l
}
# Helpers for the condition.
# workers U [G] holds when the worker group has U ungated pods that have not terminated and, if G is given, G gated ones.
workers() {
  set -- "$1" "${2-}" "$(kubectl -n "$NS" get pods -l ray.io/cluster=autoscaled-cluster,ray.io/group=workers --no-headers \
    -o custom-columns=PHASE:.status.phase,DELETING:.metadata.deletionTimestamp,GATES:.spec.schedulingGates[*].name |
    awk '$1 != "Succeeded" && $1 != "Failed" { if ($3 == "<none>") u++; else if ($2 == "<none>") g++ } END { printf "%d %d", u, g }')"
  [ "${3% *}" -eq "$1" ] && { [ -z "$2" ] || [ "${3#* }" -eq "$2" ]; }
}
# running_workers N holds when N worker pods run and none is gated, pending, or terminating.
running_workers() {
  [ "$(kubectl -n "$NS" get pods -l ray.io/cluster=autoscaled-cluster,ray.io/group=workers --no-headers \
    -o custom-columns=PHASE:.status.phase,DELETING:.metadata.deletionTimestamp | awk '$1 == "Running" && $2 == "<none>"' | wc -l)" -eq "$1" ] &&
    workers "$1" 0
}
# replicas N holds when the autoscaler has set the worker group's replicas to N.
replicas() {
  [ "$(kubectl -n "$NS" get raycluster autoscaled-cluster -o jsonpath='{.spec.workerGroupSpecs[0].replicas}')" = "$1" ]
}
# job_running J holds when both pods of Job J run.
job_running() {
  [ "$(kubectl -n "$NS" get pods -l job-name="$1" --no-headers -o custom-columns=PHASE:.status.phase | grep -c '^Running$')" -eq 2 ]
}
# job_complete J holds when Job J has succeeded.
job_complete() {
  [ "$(kubectl -n "$NS" get job "$1" -o jsonpath='{.status.succeeded}')" = 2 ]
}
start=$(date +%s)
while :; do
  slots=$(holding)
  if [ "$slots" -gt "$quota_slots" ]; then
    echo "over-commit: $slots worker and preemptor pods hold resources, the quota fits $quota_slots" >&2
    kubectl -n "$NS" get pods -o wide >&2
    exit 1
  fi
  if [ -n "$duration" ]; then
    if [ $(($(date +%s) - start)) -ge "$duration" ]; then
      eval "$condition" || { echo "condition no longer holds after ${duration}s: $condition" >&2; exit 1; }
      break
    fi
    eval "$condition" || { echo "condition stopped holding: $condition" >&2; exit 1; }
  elif eval "$condition"; then
    break
  elif [ $(($(date +%s) - start)) -ge "${WATCH_SECONDS:-280}" ]; then
    echo "condition did not hold within ${WATCH_SECONDS:-280}s: $condition" >&2
    exit 1
  fi
  sleep 0.5
done
echo "$slots worker and preemptor pods hold resources: $condition"
