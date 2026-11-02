#!/bin/sh
# Scenario 1 (Overflow): scale 0 to 12.
# Expect entries workers=8 on flavor-a and workers--2=4 on flavor-b, all pods Running with the right nodeSelectors and entry labels, and one active Workload.
set -eu

if [ -z "${TEST_FLAVOR_SPLIT:-}" ]; then
  echo "Skipping assert-overflow: TEST_FLAVOR_SPLIT is not set"
  exit 0
fi

NS="${NS:-default}"
cluster="flavor-split-cluster"
timeout="${WAIT_SECONDS:-20}"
start=$(date +%s)

echo "Waiting for RayCluster $cluster to scale 0 to 12 with flavor-split PodSets (workers and workers--2)..."

sync_running_pods() {
  for pod in $(kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster" --no-headers -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,GATES:.spec.schedulingGates[*].name,PHASE:.status.phase 2>/dev/null | awk '$2 != "<none>" && $3 == "<none>" && $4 != "Running" {print $1}'); do
    kubectl -n "$NS" patch pod "$pod" --subresource=status --type=merge -p '{"status":{"phase":"Running"}}' >/dev/null 2>&1 || true
  done
}

while true; do
  sync_running_pods

  active_wl=$(kubectl -n "$NS" get workloads -o json | jq -r '[.items[] | select(.metadata.ownerReferences[]?.name == "'"$cluster"'" and all(.status.conditions[]?; .type != "Finished" or .status != "True") and (.status.admission != null))]')
  active_count=$(echo "$active_wl" | jq 'length')

  if [ "$active_count" -eq 1 ]; then
    count_fa=$(echo "$active_wl" | jq -r '.[0].status.admission.podSetAssignments[] | select(.name == "workers") | .count // 0')
    flavor_fa=$(echo "$active_wl" | jq -r '.[0].status.admission.podSetAssignments[] | select(.name == "workers") | .flavors["nvidia.com/gpu"] // ""')

    count_fb=$(echo "$active_wl" | jq -r '.[0].status.admission.podSetAssignments[] | select(.name == "workers--2") | .count // 0')
    flavor_fb=$(echo "$active_wl" | jq -r '.[0].status.admission.podSetAssignments[] | select(.name == "workers--2") | .flavors["nvidia.com/gpu"] // ""')

    split_of=$(echo "$active_wl" | jq -r '.[0].spec.podSets[] | select(.name == "workers--2") | .template.metadata.annotations["kueue.x-k8s.io/flavor-split-of"] // ""')

    if [ "$count_fa" -eq 8 ] && [ "$flavor_fa" = "flavor-a" ] && [ "$count_fb" -eq 4 ] && [ "$flavor_fb" = "flavor-b" ]; then
      workers_fa=$(kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster,kueue.x-k8s.io/podset=workers" --no-headers -o custom-columns=NAME:.metadata.name,SEL:.spec.nodeSelector.instance-type,PHASE:.status.phase | awk '$2 == "flavor-a" && $3 == "Running" {print $1}' | wc -l)
      workers_fb=$(kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster,kueue.x-k8s.io/podset=workers--2" --no-headers -o custom-columns=NAME:.metadata.name,SEL:.spec.nodeSelector.instance-type,PHASE:.status.phase | awk '$2 == "flavor-b" && $3 == "Running" {print $1}' | wc -l)

      if [ "$workers_fa" -eq 8 ] && [ "$workers_fb" -eq 4 ]; then
        echo "SUCCESS: Scenario 1 Overflow verified!"
        echo "- Active Workloads: 1"
        echo "- workers: count=8 on flavor-a, running pods=8"
        echo "- workers--2: count=4 on flavor-b, running pods=4 (flavor-split-of: $split_of)"
        exit 0
      fi
    fi
  fi

  if [ $(($(date +%s) - start)) -ge "$timeout" ]; then
    echo "================================================================================" >&2
    echo "FAILURE: Scale-up 0 to 12 did not admit flavor-split PodSets within ${timeout}s" >&2
    echo "Active Workloads count: $active_count" >&2
    if [ "$active_count" -gt 0 ]; then
      echo "Admitted PodSetAssignments:" >&2
      echo "$active_wl" | jq -r '.[0].status.admission.podSetAssignments[] | {name: .name, count: .count, flavors: .flavors}' >&2
    fi
    echo "Pending Workloads:" >&2
    kubectl -n "$NS" get workloads -o json | jq -r '[.items[] | select(.metadata.ownerReferences[]?.name == "'"$cluster"'" and .status.admission == null)] | .[] | {name: .metadata.name, podSets: .spec.podSets, conditions: .status.conditions}' >&2
    echo "Pods in namespace $NS:" >&2
    kubectl -n "$NS" get pods -l "ray.io/cluster=$cluster" -o custom-columns=NAME:.metadata.name,PODSET:.metadata.labels.kueue\.x-k8s\.io/podset,GATES:.spec.schedulingGates[*].name,SELECTOR:.spec.nodeSelector,PHASE:.status.phase >&2
    echo "================================================================================" >&2
    echo "DIAGNOSIS: Scale-up waits on flavor-a. The Workload slice cannot split across flavors; single PodSet workers=12 exceeds flavor-a quota (8)." >&2
    exit 1
  fi
  sleep 1
done
