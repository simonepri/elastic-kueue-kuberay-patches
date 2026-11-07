#!/usr/bin/env bash
# Install generated patched-controller permissions and verify its provisioning access before scenarios begin.

set -euo pipefail

# Render the upstream name-reference transforms as well as the patched generated permissions.
kubectl kustomize third_party/kueue/config/default |
  kubectl create --dry-run=client -f - -o json |
  jq -es 'map(select(.kind == "ClusterRole" and .metadata.name == "kueue-manager-role")) |
    if length == 1 then .[0] else error("expected exactly one rendered Kueue manager role") end' |
  kubectl apply --server-side --force-conflicts -f -

kubectl auth can-i list daemonsets.apps --all-namespaces \
  --as=system:serviceaccount:kueue-system:kueue-controller-manager >/dev/null || {
  echo "Kueue cannot list DaemonSets required to size NodeClaims" >&2
  exit 1
}
