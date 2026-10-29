#!/bin/sh
# Stands in for Karpenter in Kind: waits for the gang's NodeClaims in namespace $NS and marks them Launched.
set -eu
want=$1
selector="kueue.x-k8s.io/workload-namespace=$NS"
until [ "$(kubectl get nodeclaims -l "$selector" -o name | wc -l)" -ge "$want" ]; do sleep 1; done
for nc in $(kubectl get nodeclaims -l "$selector" -o name); do
  kubectl patch "$nc" --subresource=status --type=merge \
    -p '{"status":{"conditions":[{"type":"Launched","status":"True","reason":"Launched","message":"","lastTransitionTime":"2026-01-01T00:00:00Z"}]}}'
done
