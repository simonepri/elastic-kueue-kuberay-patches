#!/usr/bin/env bash
# Build patched interLink virtual kubelet container image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INTERLINK_UPSTREAM="${INTERLINK_UPSTREAM:-$(source "$ROOT/patches/interlink/upstream.env"; printf '%s' "$INTERLINK_UPSTREAM")}"
TAG="${INTERLINK_IMAGE_TAG:-${INTERLINK_UPSTREAM}-patched}"
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
