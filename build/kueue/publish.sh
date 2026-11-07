#!/usr/bin/env bash
# Build and publish patched Kueue multi-arch image to GHCR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="${KUEUE_UPSTREAM:-v0.20.5}-p${KUEUE_PATCH_VERSION:-0.10.4}"
DOCKERFILE="$ROOT/build/kueue/Dockerfile"

"$ROOT/build/kueue/patch.sh"

echo "Publishing Kueue image ghcr.io/simonepri/kueue:$TAG..."
docker buildx build --platform linux/amd64,linux/arm64 \
  -f "$DOCKERFILE" \
  -t "ghcr.io/simonepri/kueue:$TAG" \
  -t "ghcr.io/simonepri/kueue:latest" \
  --push \
  "$ROOT/third_party/kueue"
