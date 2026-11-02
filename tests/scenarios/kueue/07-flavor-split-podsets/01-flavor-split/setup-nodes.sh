#!/bin/sh
# Sets up virtual nodes node-flavor-a and node-flavor-b to allow kube-scheduler to bind pods with nodeSelector.
set -eu

if [ -z "${TEST_FLAVOR_SPLIT:-}" ]; then
  echo "Skipping setup-nodes: TEST_FLAVOR_SPLIT is not set"
  exit 0
fi

cat << 'NODE_EOF' | kubectl apply -f -
apiVersion: v1
kind: Node
metadata:
  name: node-flavor-a
  labels:
    instance-type: flavor-a
spec:
  taints: []
---
apiVersion: v1
kind: Node
metadata:
  name: node-flavor-b
  labels:
    instance-type: flavor-b
spec:
  taints: []
NODE_EOF

kubectl patch node node-flavor-a --subresource=status --type=merge -p "{\"status\":{\"capacity\":{\"cpu\":\"64\",\"memory\":\"256Gi\",\"nvidia.com/gpu\":\"32\",\"pods\":\"110\"},\"allocatable\":{\"cpu\":\"64\",\"memory\":\"256Gi\",\"nvidia.com/gpu\":\"32\",\"pods\":\"110\"},\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"lastHeartbeatTime\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]}}"
kubectl patch node node-flavor-b --subresource=status --type=merge -p "{\"status\":{\"capacity\":{\"cpu\":\"64\",\"memory\":\"256Gi\",\"nvidia.com/gpu\":\"32\",\"pods\":\"110\"},\"allocatable\":{\"cpu\":\"64\",\"memory\":\"256Gi\",\"nvidia.com/gpu\":\"32\",\"pods\":\"110\"},\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"lastHeartbeatTime\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]}}"

echo "Initialized node-flavor-a and node-flavor-b with GPU capacity."
