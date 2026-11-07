#!/usr/bin/env bash
# Build patched KubeRay operator container image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="${KUBERAY_IMAGE_TAG:-v1.7.2-patched}"
SRC="$ROOT/third_party/kuberay/ray-operator"
DOCKERFILE="$ROOT/build/kuberay/Dockerfile"

"$ROOT/build/kuberay/patch.sh"

echo "Building KubeRay image: kind.local/kuberay-operator:$TAG..."
docker build -f "$DOCKERFILE" \
  -t "kind.local/kuberay-operator:$TAG" \
  -t "kind.local/kuberay-operator:latest" \
  "$SRC"

echo "kind.local/kuberay-operator:$TAG" > "$ROOT/.kuberay-image.txt"
echo "Built KubeRay image: kind.local/kuberay-operator:$TAG"
