#!/bin/sh
set -eu

if [ -z "${TEST_FLAVOR_SPLIT:-}" ]; then
  echo "Skipping clean-reclaim.sh: TEST_FLAVOR_SPLIT is not set"
  exit 0
fi

NS="${NS:-default}"
kubectl -n "$NS" delete job flavor-a-reclaim-job --ignore-not-found
echo "Cleaned up flavor-a-reclaim-job."
