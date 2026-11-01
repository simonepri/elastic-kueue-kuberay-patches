#!/bin/sh
# Asks the Ray autoscaler of RayCluster autoscaled-cluster in namespace $NS to hold $1 logical CPUs, as a Ray
# application does with ray.autoscaler.sdk.request_resources; the request lasts until the next one replaces it.
set -eu
head=$(kubectl -n "$NS" get pods -l ray.io/cluster=autoscaled-cluster,ray.io/node-type=head -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NS" exec "$head" -c ray-head -- python -c "
import ray
from ray.autoscaler.sdk import request_resources
ray.init(address='auto')
request_resources(num_cpus=$1)
"
