#!/usr/bin/env bash
# Spin up local Kind cluster and deploy patched controllers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

CLUSTER_NAME="${CLUSTER_NAME:-elastic-scale-lab}"
KUEUE_UPSTREAM="${KUEUE_UPSTREAM:-v0.20.5}"
KUBERAY_UPSTREAM="${KUBERAY_UPSTREAM:-v1.7.2}"
KARPENTER_UPSTREAM="${KARPENTER_UPSTREAM:-v1.15.1}"
KUEUE_FEATURE_GATES="${KUEUE_FEATURE_GATES:-ConcurrentAdmission=true,ElasticJobsViaWorkloadSlicesWithPartialReplicaScaleUp=true,ElasticJobsViaWorkloadSlicesFlavorChangeFromZero=true,PartialPreemption=true,ElasticJobsViaWorkloadSlicesFlavorSplit=true,KarpenterAdmissionCheck=true,MutableDeploymentQueue=true}"

# 1. Ensure container runtime is running (starts Colima on macOS if docker daemon is inactive)
if ! docker info >/dev/null 2>&1; then
  if command -v colima >/dev/null 2>&1; then
    echo "Starting Colima runtime..."
    colima start --cpu 4 --memory 8 || true
  fi
fi

# 2. Create Kind cluster if not already running
if ! kind get clusters | grep -q "^$CLUSTER_NAME$"; then
  echo "Creating Kind cluster $CLUSTER_NAME..."
  kind create cluster --config kind-config.yaml --name "$CLUSTER_NAME"
fi
echo "Labeling Kind nodes for elastic nodepool workloads..."
kubectl label nodes --all karpenter.sh/nodepool=elastic-nodepool --overwrite

# 3. Sideload patched images into Kind
KUEUE_IMG=$(cat .kueue-image.txt)
KUBERAY_IMG=$(cat .kuberay-image.txt)
echo "Loading images into Kind..."
kind load docker-image "$KUEUE_IMG" --name "$CLUSTER_NAME"
kind load docker-image "$KUBERAY_IMG" --name "$CLUSTER_NAME"
if [ -f .ray-image.txt ]; then
  RAY_IMG=$(cat .ray-image.txt)
  echo "Loading Ray image into Kind: $RAY_IMG..."
  kind load docker-image "$RAY_IMG" --name "$CLUSTER_NAME"
  kind load docker-image "kind.local/ray:latest" --name "$CLUSTER_NAME"
fi

# 4. Install CRDs
echo "Installing base CRDs..."
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/ray-project/kuberay/$KUBERAY_UPSTREAM/ray-operator/config/crd/bases/ray.io_rayclusters.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/ray-project/kuberay/$KUBERAY_UPSTREAM/ray-operator/config/crd/bases/ray.io_rayjobs.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/ray-project/kuberay/$KUBERAY_UPSTREAM/ray-operator/config/crd/bases/ray.io_rayservices.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/kubernetes-sigs/karpenter/$KARPENTER_UPSTREAM/pkg/apis/crds/karpenter.sh_nodeclaims.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/kubernetes-sigs/karpenter/$KARPENTER_UPSTREAM/pkg/apis/crds/karpenter.sh_nodepools.yaml

# 5. Install KubeRay operator directly with patched image, ko entrypoint, and RBAC
echo "Installing KubeRay operator with patched image..."
case ",$KUEUE_FEATURE_GATES," in
  *,ElasticJobsViaWorkloadSlicesFlavorSplit=true,*) scalegate_flavor_split=true ;;
  *) scalegate_flavor_split=false ;;
esac
helm repo add kuberay https://ray-project.github.io/kuberay-helm/ || true
helm repo update
helm template kuberay-operator kuberay/kuberay-operator \
  --version $KUBERAY_UPSTREAM \
  --set image.repository="${KUBERAY_IMG%:*}" \
  --set image.tag="${KUBERAY_IMG##*:}" \
  --set leaderElectionEnabled=false \
  --set 'featureGates[0].name=ScaleGate' \
  --set 'featureGates[0].enabled=true' \
  --set env[0].name=SCALEGATE_FLAVOR_SPLIT \
  --set-string env[0].value="$scalegate_flavor_split" \
  --set resources.limits.cpu=2 \
  --set resources.limits.memory=2Gi \
  --set resources.requests.cpu=500m \
  --set resources.requests.memory=512Mi \
  -n default | \
  sed -e "s| - /manager| - /ko-app/ray-operator|g" | \
  kubectl apply --server-side --force-conflicts -f -

cat << EOF | kubectl apply --server-side --force-conflicts -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kuberay-operator-extra
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: ["kueue.x-k8s.io"]
  resources: ["clusterqueues", "localqueues", "cohorts", "workloads"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kuberay-operator-extra
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kuberay-operator-extra
subjects:
- kind: ServiceAccount
  name: kuberay-operator
  namespace: default
EOF

# 6. Install Kueue manifests directly patched with sed
echo "Installing Kueue manifests with patched image..."
curl -sL "https://github.com/kubernetes-sigs/kueue/releases/download/$KUEUE_UPSTREAM/manifests.yaml" | \
  sed -e "s|registry.k8s.io/kueue/kueue:$KUEUE_UPSTREAM|$KUEUE_IMG|g" \
      -e "s|imagePullPolicy: Always|imagePullPolicy: IfNotPresent|g" \
      -e "s| - /manager| - /ko-app/kueue|g" | \
  kubectl apply --server-side --force-conflicts -f -

cat << EOF | kubectl apply --server-side --force-conflicts -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kueue-karpenter-nodeclaims
rules:
- apiGroups: ["karpenter.sh"]
  resources: ["nodeclaims"]
  verbs: ["get", "list", "create", "patch", "delete"]
- apiGroups: ["karpenter.sh"]
  resources: ["nodepools"]
  verbs: ["get"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kueue-karpenter-nodeclaims
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kueue-karpenter-nodeclaims
subjects:
- kind: ServiceAccount
  name: kueue-controller-manager
  namespace: kueue-system
EOF

# Apply patched generated manager role
bash build/kueue/install-rbac.sh

# Register RayCluster webhook for UPDATE operations
raycluster_webhook=$(kubectl get mutatingwebhookconfiguration kueue-mutating-webhook-configuration -o jsonpath='{.webhooks[*].name}' |
  awk '{for (i = 1; i <= NF; i++) if ($i == "mraycluster.kb.io") print i - 1}')
kubectl patch mutatingwebhookconfiguration kueue-mutating-webhook-configuration --type=json \
  -p '[{"op":"add","path":"/webhooks/'"$raycluster_webhook"'/rules/0/operations/-","value":"UPDATE"}]'
rayjob_webhook=$(kubectl get mutatingwebhookconfiguration kueue-mutating-webhook-configuration -o jsonpath='{.webhooks[*].name}' |
  awk '{for (i = 1; i <= NF; i++) if ($i == "mrayjob.kb.io") print i - 1}')
if [ -n "$rayjob_webhook" ]; then
  kubectl patch mutatingwebhookconfiguration kueue-mutating-webhook-configuration --type=json \
    -p '[{"op":"add","path":"/webhooks/'"$rayjob_webhook"'/rules/0/operations/-","value":"UPDATE"}]'
fi

echo "Enabling Kueue feature gates: $KUEUE_FEATURE_GATES"
kubectl patch deployment/kueue-controller-manager -n kueue-system --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--feature-gates='"$KUEUE_FEATURE_GATES"'"}]'
kubectl set resources deployment/kueue-controller-manager -n kueue-system --limits=memory=2Gi --requests=memory=512Mi

# 7. Wait for rollouts
kubectl rollout status deployment/kueue-controller-manager -n kueue-system --timeout=180s
kubectl rollout status deployment/kuberay-operator -n default --timeout=180s

# 8. Wait until every webhook accepts a server-side dry run
probe() {
  manifest=$(cat)
  for _ in $(seq 1 120); do
    if echo "$manifest" | kubectl create --dry-run=server -f - >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Webhook probe $1 did not succeed within 120s" >&2
  exit 1
}

echo "Waiting for Kueue and KubeRay webhooks to accept requests..."
probe resourceflavor <<EOF
apiVersion: kueue.x-k8s.io/v1beta2
kind: ResourceFlavor
metadata:
  name: webhook-probe
EOF

probe clusterqueue <<EOF
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: webhook-probe
spec:
  resourceGroups: []
EOF

probe localqueue <<EOF
apiVersion: kueue.x-k8s.io/v1beta2
kind: LocalQueue
metadata:
  name: webhook-probe
  namespace: default
spec:
  clusterQueue: webhook-probe
EOF

probe pod <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: webhook-probe
  namespace: default
spec:
  containers:
    - name: probe
      image: busybox:latest
EOF

probe raycluster <<EOF
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: webhook-probe
  namespace: default
spec:
  headGroupSpec:
    rayStartParams: {}
    template:
      spec:
        containers:
          - name: ray-head
            image: rayproject/ray:2.38.0
EOF

echo "Kueue and KubeRay webhooks are ready!"
echo "Cluster $CLUSTER_NAME is ready with patched controllers!"
