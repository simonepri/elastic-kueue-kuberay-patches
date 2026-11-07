#!/usr/bin/env bash
# Build and publish patched KubeRay multi-arch image to GHCR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="${KUBERAY_UPSTREAM:-v1.7.2}-p${KUBERAY_PATCH_VERSION:-0.5.0}"
DOCKERFILE="$ROOT/build/kuberay/Dockerfile"

"$ROOT/build/kuberay/patch.sh"

echo "Publishing KubeRay image ghcr.io/simonepri/kuberay-operator:$TAG..."
docker buildx build --platform linux/amd64,linux/arm64 \
  -f "$DOCKERFILE" \
  -t "ghcr.io/simonepri/kuberay-operator:$TAG" \
  -t "ghcr.io/simonepri/kuberay-operator:latest" \
  --push \
  "$ROOT/third_party/kuberay/ray-operator"
