#!/bin/sh
set -eu

if [ -z "${TEST_FLAVOR_SPLIT:-}" ]; then
  echo "Skipping scale.sh: TEST_FLAVOR_SPLIT is not set"
  exit 0
fi

NS="${NS:-default}"
cluster="flavor-split-cluster"
replicas="$1"

kubectl -n "$NS" patch raycluster "$cluster" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/workerGroupSpecs/0/replicas\",\"value\":$replicas}]"
echo "Patched RayCluster $cluster workerGroup replicas to $replicas"
