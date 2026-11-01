#!/bin/sh
# Prints the RayClusters, Workloads, Pods, and events of namespace $NS, and Kueue's log lines about it, to diagnose a failed step.
kubectl -n "$NS" get rayclusters -o yaml
kubectl -n "$NS" get workloads -o yaml
kubectl -n "$NS" get pods -o wide --show-labels
kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -60
kubectl -n kueue-system logs deployment/kueue-controller-manager --tail=-1 | grep -F "$NS" | tail -150
