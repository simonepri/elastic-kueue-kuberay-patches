#!/bin/bash
# Kind has no Karpenter: simulate launch/registration and kubelet Node status.
# The actual Kueue controllers and kube-scheduler perform admission and pod binding.
set -euo pipefail
. ./bounded-waits.sh
selector="kueue.x-k8s.io/workload-namespace=$NS"
cleanup() {
  initial_status=$?
  rc=0
  if [ "$initial_status" != 0 ]; then
    kubectl -n "$NS" get workloads,pods -o yaml >&2 || true
    kubectl get nodes -l "example.com/delayed-tas-test=$NS" -o yaml >&2 || true
  fi
  kubectl -n "$NS" delete pod rogue --ignore-not-found --force --grace-period=0 --timeout=10s >/dev/null || rc=$?
  ./finish-job.sh delayed-tas-gang || rc=$?
  kubectl delete node -l "example.com/delayed-tas-test=$NS" --ignore-not-found --timeout=10s >/dev/null || rc=$?
  if [ "$initial_status" != 0 ]; then return "$initial_status"; fi
  return "$rc"
}
trap cleanup EXIT
wait_for_count 3 get nodeclaims -l "$selector"
claims=$(kubectl get nodeclaims -l "$selector" -o json)
# Half of 1 CPU minus Kind's 100m daemon request fits one 250m pod per claim.
echo "$claims" | jq -e '([.items[].metadata.annotations["kueue.x-k8s.io/karpenter-pods"]] | sort) == ["1","1","1"]'
wl=$(echo "$claims" | jq -r '.items[0].metadata.annotations["kueue.x-k8s.io/workload"] // .items[0].metadata.labels["kueue.x-k8s.io/workload"]')
uid=$(echo "$claims" | jq -r '.items[0].metadata.labels["kueue.x-k8s.io/workload"]')
attempt=$(echo "$claims" | jq -r '.items[0].metadata.labels["kueue.x-k8s.io/karpenter-attempt"]')
assert_pending() {
  kubectl -n "$NS" get workload "$wl" -o json | jq -e '
    any(.status.conditions[]; .type == "QuotaReserved" and .status == "True") and
    (any(.status.conditions[]; .type == "Admitted" and .status == "True") | not) and
    .status.admission.podSetAssignments[0].delayedTopologyRequest == "Pending" and
    .status.admission.podSetAssignments[0].topologyAssignment == null'
}
assert_pending
for nc in $(echo "$claims" | jq -r '.items[].metadata.name'); do
  kubectl patch nodeclaim "$nc" --subresource=status --type=merge -p '{"status":{"conditions":[{"type":"Launched","status":"True","reason":"Launched","message":"","lastTransitionTime":"2026-01-01T00:00:00Z"}]}}'
done
# Give the check a full polling interval to observe Launched, which is insufficient for TAS.
sleep 12
assert_pending
for nc in $(echo "$claims" | jq -r '.items[].metadata.name'); do
  node="tas-$nc"
  kubectl get nodeclaim "$nc" -o json | jq --arg name "$node" --arg ns "$NS" '{
    apiVersion:"v1", kind:"Node", metadata:{name:$name, labels:(.metadata.labels + {
      "kubernetes.io/hostname":$name, "kubernetes.io/os":"linux", "example.com/delayed-tas-test":$ns
    })}, spec:{taints:.spec.taints}
  }' | kubectl create -f -
  # Advertise the instance's CPU capacity, leaving room for Kind's DaemonSets.
  # TAS may pack more densely than the conservative one-pod claim requests.
  kubectl patch node "$node" --subresource=status --type=merge -p "$(jq -nc --arg cpu "1" '{status:{capacity:{cpu:$cpu,memory:"1Gi",pods:"10"},allocatable:{cpu:$cpu,memory:"1Gi",pods:"10"},conditions:[{type:"Ready",status:"True",reason:"KubeletReady",message:"simulated kubelet"}]}}')"
  kubectl patch nodeclaim "$nc" --subresource=status --type=merge -p "$(jq -nc --arg node "$node" '{status:{nodeName:$node,conditions:[{type:"Launched",status:"True",reason:"Launched",message:"",lastTransitionTime:"2026-01-01T00:00:00Z"},{type:"Registered",status:"True",reason:"Registered",message:"",lastTransitionTime:"2026-01-01T00:00:00Z"}]}}')"
done
# A rogue pod has the same node selector but lacks the workload-specific toleration.
jq -nc --arg attempt "$attempt" '{apiVersion:"v1",kind:"Pod",metadata:{name:"rogue"},spec:{nodeSelector:{"kueue.x-k8s.io/karpenter-attempt":$attempt},containers:[{name:"rogue",image:"busybox:latest",command:["sleep","300"]}]}}' | kubectl -n "$NS" create -f -
deadline=$(($(date +%s) + 50))
while [ "$(date +%s)" -lt "$deadline" ]; do
  # Maintain fake Node health while controllers reconcile.
  for node in $(kubectl get nodes -l "example.com/delayed-tas-test=$NS" -o name); do
    kubectl patch "$node" --subresource=status --type=merge -p "$(jq -nc --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{status:{conditions:[{type:"Ready",status:"True",reason:"KubeletReady",message:"simulated kubelet",lastHeartbeatTime:$now}]}}')" >/dev/null
  done
  if kubectl -n "$NS" get pods -l job-name=delayed-tas-gang -o json | jq -e '
      (.items | length) == 3 and all(.items[]; (.spec.nodeName // "" | startswith("tas-")) and (.spec.schedulingGates | length) == 0)' >/dev/null; then break; fi
  sleep 1
done
kubectl -n "$NS" get workload "$wl" -o json | jq -L . -e --arg attempt "$attempt" --arg wl "$wl" --arg uid "$uid" '
  include "topology"; with_domains |
  any(.status.conditions[]; .type == "Admitted" and .status == "True") and
  .status.admission.podSetAssignments[0].delayedTopologyRequest == "Ready" and
  (.status.admission.podSetAssignments[0].topologyAssignment.domains | map(.count) | add) == 3 and
  all(.status.admission.podSetAssignments[0].topologyAssignment.domains[]; .values[-1] | startswith("tas-")) and
  any(.status.admissionChecks[].podSetUpdates[]; .nodeSelector["kueue.x-k8s.io/karpenter-attempt"] == $attempt and any(.tolerations[]; .key == "karpenter.sh/claimed-by" and (.value == $wl or .value == $uid) and .operator == "Equal"))'
kubectl -n "$NS" get pods -l job-name=delayed-tas-gang -o json | jq -e '(.items | length) == 3 and all(.items[]; (.spec.nodeName // "" | startswith("tas-")))'
kubectl get nodes -l "example.com/delayed-tas-test=$NS" -o json | jq -e --arg wl "$wl" --arg uid "$uid" '(.items | length) == 3 and all(.items[]; any(.spec.taints[]; .key == "karpenter.sh/claimed-by" and (.value == $wl or .value == $uid) and .effect == "NoSchedule"))'
kubectl -n "$NS" wait pod rogue --for=condition=PodScheduled=False --timeout=15s
kubectl -n "$NS" get pod rogue -o json | jq -e '(.spec.nodeName // "") == "" and any(.status.conditions[]; .type == "PodScheduled" and .status == "False" and (.message | contains("untolerated taint")))'
# Every bound pod is on one of the domains actually assigned by TAS.
assigned=$(kubectl -n "$NS" get workload "$wl" -o json | jq -L . 'include "topology"; with_domains | [.status.admission.podSetAssignments[0].topologyAssignment.domains[].values[-1]]')
kubectl -n "$NS" get pods -l job-name=delayed-tas-gang -o json | jq -e --argjson assigned "$assigned" 'all(.items[]; .spec.nodeName as $node | $assigned | index($node) != null)'
