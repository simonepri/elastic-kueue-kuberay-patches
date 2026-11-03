#!/bin/bash
set -eu
NS="${NS:-default}"

# Patch all scheduled Pending pods to Running
patch_scheduled_pods() {
  kubectl -n "$NS" get pods -o json | jq -r '.items[] | select(.spec.nodeName != null and .spec.nodeName != "" and .status.phase == "Pending" and .metadata.deletionTimestamp == null) | .metadata.name' | while read -r name; do
    [ -z "$name" ] && continue
    kubectl -n "$NS" patch pod "$name" --subresource=status --type=merge \
      -p '{"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}' >/dev/null 2>&1 || true
  done
}

# Run once or loop
if [ "${1:-}" = "once" ]; then
  patch_scheduled_pods
else
  # Background daemon mode
  while true; do
    patch_scheduled_pods
    sleep 0.5
  done
fi
