#!/bin/sh
# Fails if a webhook rejected a write that Kueue, the KubeRay operator, or the Ray autoscaler made for namespace $NS.
set -eu
rejected=$( {
  kubectl -n kueue-system logs deployment/kueue-controller-manager --tail=-1 | grep -F "$NS" || true
  kubectl -n default logs deployment/kuberay-operator --tail=-1 | grep -F "$NS" || true
  kubectl -n "$NS" logs -l ray.io/cluster=autoscaled-cluster,ray.io/node-type=head -c autoscaler --tail=-1 || true
} | grep -E 'denied the request|is invalid' || true)
if [ -n "$rejected" ]; then
  echo "rejected writes:" >&2
  echo "$rejected" >&2
  exit 1
fi
