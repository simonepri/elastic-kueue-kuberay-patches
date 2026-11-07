#!/bin/bash
# Kind has no Karpenter: simulate registration of nodes too small for the gang's topology.
# Packing sizes the claims from pod requests; TAS then finds no room on the registered nodes.
set -euo pipefail
cleanup() {
  rc=$?
  if [ "$rc" != 0 ]; then
    kubectl -n "$NS" get workloads,pods -o yaml >&2 || true
    kubectl get nodeclaims -o yaml >&2 || true
  fi
  ./finish-job.sh delayed-tas-small-gang || rc=$?
  kubectl delete node -l "example.com/delayed-tas-test=$NS" --ignore-not-found >/dev/null
  return "$rc"
}
trap cleanup EXIT
selector="kueue.x-k8s.io/workload-namespace=$NS"
heartbeat() {
  for node in $(kubectl get nodes -l "example.com/delayed-tas-test=$NS" -o name) node/delayed-tas-reserved; do
    kubectl patch "$node" --subresource=status --type=merge -p "$(jq -nc --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{status:{conditions:[{type:"Ready",status:"True",reason:"KubeletReady",message:"simulated kubelet",lastHeartbeatTime:$now}]}}')" >/dev/null
  done
}
# Wait for the preceding gang's claims to be cleaned up.
until [ "$(kubectl get nodeclaims -l "$selector" -o json | jq '.items | length')" = 0 ]; do sleep 1; done
sed -e 's/name: delayed-tas-gang/name: delayed-tas-small-gang/' -e 's/queue-name: delayed-tas$/queue-name: delayed-tas-fallback/' 01-job.yaml | kubectl -n "$NS" create -f -
until [ "$(kubectl get nodeclaims -l "$selector" -o json | jq '.items | length')" = 2 ]; do sleep 1; done
wl=$(kubectl get nodeclaims -l "$selector" -o json | jq -r '.items[0].metadata.labels["kueue.x-k8s.io/workload"]')
# Register both claims on nodes that advertise 100m CPU, below one 250m pod.
for nc in $(kubectl get nodeclaims -l "$selector" -o name); do
  node="tas-small-${nc#*/}"
  kubectl get "$nc" -o json | jq --arg name "$node" --arg ns "$NS" '{
    apiVersion:"v1", kind:"Node", metadata:{name:$name, labels:(.metadata.labels + {
      "kubernetes.io/hostname":$name, "kubernetes.io/os":"linux", "example.com/delayed-tas-test":$ns
    })}, spec:{taints:.spec.taints}
  }' | kubectl create -f -
  kubectl patch node "$node" --subresource=status --type=merge -p "$(jq -nc '{status:{capacity:{cpu:"100m",memory:"1Gi",pods:"10"},allocatable:{cpu:"100m",memory:"1Gi",pods:"10"},conditions:[{type:"Ready",status:"True",reason:"KubeletReady",message:"simulated kubelet"}]}}')"
  kubectl patch "$nc" --subresource=status --type=merge -p "$(jq -nc --arg node "$node" '{status:{nodeName:$node,conditions:[{type:"Launched",status:"True",reason:"Launched",message:"",lastTransitionTime:"2026-01-01T00:00:00Z"},{type:"Registered",status:"True",reason:"Registered",message:"",lastTransitionTime:"2026-01-01T00:00:00Z"}]}}')"
done
# Registration turns the check Ready, but TAS cannot place the gang, so the topology stays Pending.
for i in $(seq 1 30); do
  heartbeat
  if kubectl -n "$NS" get workload "$wl" -o json | jq -e 'any(.status.admissionChecks[]; .state == "Ready")' >/dev/null; then break; fi
  sleep 1
done
kubectl -n "$NS" get workload "$wl" -o json | jq -e '
  any(.status.conditions[]; .type == "QuotaReserved" and .status == "True") and
  (any(.status.conditions[]; .type == "Admitted" and .status == "True") | not) and
  .status.admission.podSetAssignments[0].flavors.cpu == "delayed-tas-karpenter" and
  .status.admission.podSetAssignments[0].delayedTopologyRequest == "Pending"'
# The launch deadline keeps running: the claims are released and the workload moves to the reserved flavor.
for i in $(seq 1 90); do
  heartbeat
  if kubectl -n "$NS" get workload "$wl" -o json | jq -e '
      any(.status.conditions[]; .type == "Admitted" and .status == "True") and
      .status.admission.podSetAssignments[0].flavors.cpu == "delayed-tas-reserved"' >/dev/null; then break; fi
  sleep 1
done
kubectl -n "$NS" get workload "$wl" -o json | jq -L . -e '
  include "topology"; with_domains |
  any(.status.conditions[]; .type == "Admitted" and .status == "True") and
  .status.admission.podSetAssignments[0].flavors.cpu == "delayed-tas-reserved" and
  .status.admission.podSetAssignments[0].delayedTopologyRequest == null and
  .status.admission.podSetAssignments[0].topologyAssignment.domains == [{count:3, values:["delayed-tas-reserved"]}]'
kubectl get nodeclaims -l "$selector" -o json | jq -e '.items | length == 0'
