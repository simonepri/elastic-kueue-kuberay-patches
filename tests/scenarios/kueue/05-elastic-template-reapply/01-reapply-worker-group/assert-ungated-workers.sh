#!/bin/sh
# Waits until $1 workers of the RayCluster in namespace $NS are ungated and $2 (default $1) exist, then checks for 15s that no more are ungated.
set -eu
want=$1
total=${2:-$1}
selector=ray.io/cluster=reapplied-cluster,ray.io/group=workers
ungated() {
  kubectl -n "$NS" get pods -l "$selector" --no-headers \
    -o custom-columns=DELETING:.metadata.deletionTimestamp,GATES:.spec.schedulingGates[*].name |
    awk '$1 == "<none>" && $2 == "<none>" { n++ } END { print n + 0 }'
}
pods() {
  kubectl -n "$NS" get pods -l "$selector" --no-headers -o custom-columns=DELETING:.metadata.deletionTimestamp |
    awk '$1 == "<none>" { n++ } END { print n + 0 }'
}
until [ "$(ungated)" -eq "$want" ] && [ "$(pods)" -eq "$total" ]; do sleep 1; done
end=$(( $(date +%s) + 15 ))
while [ "$(date +%s)" -lt "$end" ]; do
  got=$(ungated)
  if [ "$got" -gt "$want" ]; then
    echo "$got workers are ungated, but Kueue admitted $want" >&2
    exit 1
  fi
  sleep 1
done
kubectl -n "$NS" get pods -l "$selector" -o custom-columns=NAME:.metadata.name,GATES:.spec.schedulingGates[*].name
