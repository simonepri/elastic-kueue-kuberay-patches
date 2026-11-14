#!/usr/bin/env bash
# Refuses to continue unless kubectl targets this repository's kind cluster through the repository's own kubeconfig,
# so lab setup and tests can never apply CRDs, controllers or node labels to another cluster.
set -euo pipefail

fail() {
  echo "refusing to touch a cluster: $1" >&2
  echo "run cluster tasks through mise, which points KUBECONFIG at this repository's kind kubeconfig" >&2
  exit 1
}

[ -n "${CLUSTER_NAME:-}" ] || fail "CLUSTER_NAME is not set"
[ -n "${KUBECONFIG:-}" ] || fail "KUBECONFIG is not set, so kubectl would use the default kubeconfig"
case "$KUBECONFIG" in *:*) fail "KUBECONFIG lists several files ($KUBECONFIG)" ;; esac
[ "$KUBECONFIG" != "$HOME/.kube/config" ] || fail "KUBECONFIG is the default kubeconfig"

context="$(kubectl config current-context 2>/dev/null)" || fail "kubeconfig $KUBECONFIG has no current context"
[ "$context" = "kind-$CLUSTER_NAME" ] || fail "current context is '$context', not 'kind-$CLUSTER_NAME'"

server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
case "$server" in
  https://127.0.0.1:* | https://localhost:* | https://\[::1\]:*) ;;
  *) fail "context kind-$CLUSTER_NAME points at $server, not a local kind API server" ;;
esac
