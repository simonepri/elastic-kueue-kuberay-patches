#!/bin/sh
# Checks that the head and worker templates of the RayCluster in namespace $NS carry no node label or toleration of a ResourceFlavor.
set -eu
until [ "$(kubectl -n "$NS" get raycluster from-zero-cluster -o jsonpath='{.spec.suspend}')" = false ]; do sleep 1; done
for group in headGroupSpec workerGroupSpecs.0; do
  spec=$(kubectl -n "$NS" get raycluster from-zero-cluster -o "jsonpath={.spec.$group.template.spec}")
  case "$spec" in
    *example.com/class*|*example.com/provider*)
      echo "$group template carries flavor placement: $spec" >&2
      exit 1
      ;;
  esac
done
