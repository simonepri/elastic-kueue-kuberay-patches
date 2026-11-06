#!/bin/bash
set -euo pipefail
selector="kueue.x-k8s.io/workload-namespace=$NS"
# Wait for the preceding gang's claims to be cleaned up.
until [ "$(kubectl get nodeclaims -l "$selector" -o json | jq '.items | length')" = 0 ]; do sleep 1; done
kubectl patch node delayed-tas-reserved --subresource=status --type=merge -p '{"status":{"capacity":{"cpu":"4","memory":"1Gi","pods":"10"},"allocatable":{"cpu":"4","memory":"1Gi","pods":"10"},"conditions":[{"type":"Ready","status":"True","reason":"KubeletReady","message":"simulated kubelet"}]}}'
# Reuse the same indexed gang on the fallback queue; Karpenter never launches these claims.
sed -e 's/name: delayed-tas-gang/name: delayed-tas-fallback-gang/' -e 's/queue-name: delayed-tas$/queue-name: delayed-tas-fallback/' 01-job.yaml | kubectl -n "$NS" create -f -
until [ "$(kubectl get nodeclaims -l "$selector" -o json | jq '.items | length')" = 2 ]; do sleep 1; done
wl=$(kubectl get nodeclaims -l "$selector" -o json | jq -r '.items[0].metadata.labels["kueue.x-k8s.io/workload"]')
for i in $(seq 1 60); do
  kubectl patch node delayed-tas-reserved --subresource=status --type=merge -p "$(jq -nc --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{status:{conditions:[{type:"Ready",status:"True",reason:"KubeletReady",message:"simulated kubelet",lastHeartbeatTime:$now}]}}')" >/dev/null
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
  .status.admission.podSetAssignments[0].topologyAssignment.domains == [{count:3, values:["delayed-tas-reserved"]}] and
  all(.status.admissionChecks[]; .state == "Ready" and (.podSetUpdates // [] | length) == 0)'
kubectl get nodeclaims -l "$selector" -o json | jq -e '.items | length == 0'
until [ "$(kubectl -n "$NS" get pods -l job-name=delayed-tas-fallback-gang -o json | jq '.items | length')" = 3 ]; do sleep 1; done
kubectl -n "$NS" wait pod -l job-name=delayed-tas-fallback-gang --for=condition=PodScheduled --timeout=15s
kubectl -n "$NS" get pods -l job-name=delayed-tas-fallback-gang -o json | jq -e '(.items | length) == 3 and all(.items[]; .spec.nodeName == "delayed-tas-reserved")'
