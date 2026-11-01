#!/bin/sh
# Prints the state ../../../dump-namespace.sh prints, plus the ClusterQueue and the Ray autoscaler's recent log, to diagnose a failed step.
../../../dump-namespace.sh
kubectl get clusterqueue autoscaler-cluster-queue -o yaml
kubectl -n "$NS" logs -l ray.io/cluster=autoscaled-cluster,ray.io/node-type=head -c autoscaler --tail=100
