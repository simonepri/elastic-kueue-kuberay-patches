#!/bin/sh
# Stands in for Karpenter in Kind: records node $NODE as the Node of every NodeClaim in namespace $NS.
set -eu
for nc in $(kubectl get nodeclaims -l "kueue.x-k8s.io/workload-namespace=$NS" -o name); do
  kubectl patch "$nc" --subresource=status --type=merge -p "{\"status\":{\"nodeName\":\"$NODE\"}}"
done
