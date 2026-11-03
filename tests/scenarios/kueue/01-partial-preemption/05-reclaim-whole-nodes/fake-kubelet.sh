#!/bin/bash
set -eu
NS="${NS:-default}"

patch_fake_kubelet() {
  # 1. Keep fake nodes Ready so kube-scheduler can schedule pods on them.
  for node in fake-gpu-node-a fake-gpu-node-b; do
    kubectl patch node "$node" --subresource=status --type=merge -p '{
      "status": {
        "conditions": [
          {
            "type": "Ready",
            "status": "True",
            "reason": "KubeletReady",
            "message": "kubelet is posting ready status"
          }
        ]
      }
    }' >/dev/null 2>&1 || true
  done

  # 2. Patch all scheduled Pending pods to Running
  kubectl -n "$NS" get pods -o json 2>/dev/null | jq -r '.items[] | select(.spec.nodeName != null and .spec.nodeName != "" and .status.phase == "Pending" and .metadata.deletionTimestamp == null) | .metadata.name' 2>/dev/null | while read -r name; do
    [ -z "$name" ] && continue
    kubectl -n "$NS" patch pod "$name" --subresource=status --type=merge \
      -p '{"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}' >/dev/null 2>&1 || true
  done

  # 3. Force-delete pods marked for deletion on fake nodes so etcd frees resources immediately
  kubectl -n "$NS" get pods -o json 2>/dev/null | jq -r '.items[] | select(.spec.nodeName != null and .spec.nodeName != "" and .metadata.deletionTimestamp != null) | .metadata.name' 2>/dev/null | while read -r name; do
    [ -z "$name" ] && continue
    kubectl -n "$NS" delete pod "$name" --force --grace-period=0 >/dev/null 2>&1 || true
  done
}

if [ "${1:-}" = "once" ]; then
  patch_fake_kubelet
else
  while true; do
    patch_fake_kubelet
    sleep 0.5
  done
fi
