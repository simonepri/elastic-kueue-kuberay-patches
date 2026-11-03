#!/bin/sh
set -eu

for node in fake-gpu-node-a fake-gpu-node-b; do
  kubectl patch node "$node" --subresource=status --type=merge -p '{
    "status": {
      "capacity": {
        "cpu": "32",
        "memory": "128Gi",
        "pods": "110",
        "nvidia.com/gpu": "4"
      },
      "allocatable": {
        "cpu": "32",
        "memory": "128Gi",
        "pods": "110",
        "nvidia.com/gpu": "4"
      },
      "conditions": [
        {
          "type": "Ready",
          "status": "True",
          "reason": "KubeletReady",
          "message": "kubelet is posting ready status"
        }
      ]
    }
  }'
done
echo "Configured status on fake-gpu-node-a and fake-gpu-node-b"
