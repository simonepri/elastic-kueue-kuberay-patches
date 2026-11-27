#!/usr/bin/env bash
# Build patched Kueue container image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUEUE_UPSTREAM="${KUEUE_UPSTREAM:-$(source "$ROOT/patches/kueue/upstream.env"; printf '%s' "$KUEUE_UPSTREAM")}"
TAG="${KUEUE_IMAGE_TAG:-${KUEUE_UPSTREAM}-patched}"
SRC="$ROOT/third_party/kueue"
DOCKERFILE="$ROOT/build/kueue/Dockerfile"

"$ROOT/build/kueue/patch.sh"

echo "Building Kueue image: kind.local/kueue:$TAG..."
docker build -f "$DOCKERFILE" \
  -t "kind.local/kueue:$TAG" \
  -t "kind.local/kueue:latest" \
  "$SRC"

echo "kind.local/kueue:$TAG" > "$ROOT/.kueue-image.txt"
echo "Built Kueue image: kind.local/kueue:$TAG"
