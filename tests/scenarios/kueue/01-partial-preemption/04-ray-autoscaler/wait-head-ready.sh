#!/bin/sh
# Waits until the head pod of RayCluster autoscaled-cluster in namespace $NS exists and is Ready, which includes pulling the Ray image.
set -eu
selector=ray.io/cluster=autoscaled-cluster,ray.io/node-type=head
until kubectl -n "$NS" get pods -l "$selector" -o name | grep -q .; do
  sleep 1
done
kubectl -n "$NS" wait pod -l "$selector" --for=condition=Ready --timeout=590s
