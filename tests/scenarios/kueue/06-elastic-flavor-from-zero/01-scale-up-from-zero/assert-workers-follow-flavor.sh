#!/bin/sh
# Waits until $1 workers of the RayCluster in namespace $NS are ungated, then checks each carries the provider label and toleration of flavor "fz-remote".
set -eu
want=$1
selector=ray.io/cluster=from-zero-cluster,ray.io/group=workers
ungated() {
  kubectl -n "$NS" get pods -l "$selector" --no-headers \
    -o custom-columns=NAME:.metadata.name,DELETING:.metadata.deletionTimestamp,GATES:.spec.schedulingGates[*].name |
    awk '$2 == "<none>" && $3 == "<none>" { print $1 }'
}
until [ "$(ungated | wc -l)" -ge "$want" ]; do sleep 1; done
for pod in $(ungated); do
  provider=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.nodeSelector.example\.com/provider}')
  toleration=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.tolerations[?(@.key=="example.com/provider")].value}')
  if [ "$provider" != remote ] || [ "$toleration" != remote ]; then
    echo "pod $pod was ungated without the placement of flavor fz-remote: nodeSelector provider=\"$provider\", toleration=\"$toleration\"" >&2
    exit 1
  fi
done
kubectl -n "$NS" get pods -l "$selector" -o custom-columns=NAME:.metadata.name,GATES:.spec.schedulingGates[*].name,SELECTOR:.spec.nodeSelector
