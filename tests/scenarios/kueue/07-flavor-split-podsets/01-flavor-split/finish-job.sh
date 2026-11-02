#!/bin/sh
set -eu

if [ -z "${TEST_FLAVOR_SPLIT:-}" ]; then
  echo "Skipping finish-job.sh: TEST_FLAVOR_SPLIT is not set"
  exit 0
fi

NS="${NS:-default}"
cluster="flavor-split-cluster"

kubectl -n "$NS" delete raycluster "$cluster" --ignore-not-found
echo "Deleted RayCluster $cluster to finish job."
