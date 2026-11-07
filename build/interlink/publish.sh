#!/usr/bin/env bash
# Build and publish patched interLink virtual kubelet multi-arch image to GHCR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="${INTERLINK_UPSTREAM:-0.6.2}-p${INTERLINK_PATCH_VERSION:-0.5.0}"
DOCKERFILE="$ROOT/build/interlink/Dockerfile"

"$ROOT/build/interlink/patch.sh"

echo "Publishing interLink virtual kubelet image ghcr.io/simonepri/interlink-virtual-kubelet:$TAG..."
docker buildx build --platform linux/amd64,linux/arm64 \
  -f "$DOCKERFILE" \
  --build-arg VERSION="$TAG" \
  -t "ghcr.io/simonepri/interlink-virtual-kubelet:$TAG" \
  -t "ghcr.io/simonepri/interlink-virtual-kubelet:latest" \
  --push \
  "$ROOT/third_party/interlink"
