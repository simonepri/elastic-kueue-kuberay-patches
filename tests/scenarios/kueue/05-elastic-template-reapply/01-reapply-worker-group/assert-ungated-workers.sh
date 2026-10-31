#!/bin/sh
# Waits until exactly $1 workers of the RayCluster in namespace $NS are ungated, then checks for 15s that no more are.
set -eu
want=$1
selector=ray.io/cluster=reapplied-cluster,ray.io/group=workers
ungated() {
  kubectl -n "$NS" get pods -l "$selector" --no-headers \
    -o custom-columns=DELETING:.metadata.deletionTimestamp,GATES:.spec.schedulingGates[*].name |
    awk '$1 == "<none>" && $2 == "<none>" { n++ } END { print n + 0 }'
}
until [ "$(ungated)" -eq "$want" ]; do sleep 1; done
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
