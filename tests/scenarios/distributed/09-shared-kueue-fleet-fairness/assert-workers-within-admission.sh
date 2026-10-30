#!/usr/bin/env bash
# Fails when a RayCluster runs more worker pods of a group than the admitted Workload slice grants it.
# Usage: NS=<namespace> assert-workers-within-admission.sh <raycluster> <podset>
set -euo pipefail
cluster=$1
podset=$2
# Granted workers of the admitted, unfinished Workload slice that the cluster owns.
granted=$(kubectl get workloads -n "$NS" -o json | jq --arg c "$cluster" --arg p "$podset" '
  [.items[]
   | select(any(.metadata.ownerReferences[]?; .name == $c))
   | select(.status.admission != null)
   | select(all((.status.conditions // [])[]; .type != "Finished" or .status != "True"))
   | .status.admission.podSetAssignments[] | select(.name == $p) | .count]
  | max // 0')
# Worker pods that are no longer held by Kueue's elastic job scheduling gate.
ungated=$(kubectl get pods -n "$NS" -l "ray.io/cluster=$cluster,ray.io/node-type=worker" -o json | jq '
  [.items[]
   | select(.metadata.deletionTimestamp == null)
   | select(all((.spec.schedulingGates // [])[]; .name != "kueue.x-k8s.io/elastic-job"))]
  | length')
echo "cluster=$cluster podset=$podset granted=$granted ungated=$ungated"
if [ "$ungated" -gt "$granted" ]; then
  echo "more worker pods run than the admitted slice grants" >&2
  exit 1
fi
