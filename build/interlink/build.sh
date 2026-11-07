#!/usr/bin/env bash
# Build patched interLink virtual kubelet container image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="${INTERLINK_IMAGE_TAG:-0.6.2-patched}"
SRC="$ROOT/third_party/interlink"
DOCKERFILE="$ROOT/build/interlink/Dockerfile"

"$ROOT/build/interlink/patch.sh"

echo "Building interLink image: kind.local/interlink-virtual-kubelet:$TAG..."
docker build -f "$DOCKERFILE" \
  --build-arg VERSION="$TAG" \
  -t "kind.local/interlink-virtual-kubelet:$TAG" \
  -t "kind.local/interlink-virtual-kubelet:latest" \
  "$SRC"

echo "kind.local/interlink-virtual-kubelet:$TAG" > "$ROOT/.interlink-image.txt"
echo "Built interLink image: kind.local/interlink-virtual-kubelet:$TAG"
