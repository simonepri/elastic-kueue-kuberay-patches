#!/usr/bin/env bash
# Apply patches to upstream KubeRay clone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPSTREAM="${KUBERAY_UPSTREAM:-v1.7.2}"
TARGET="$ROOT/third_party/kuberay"
PATCH_DIR="$ROOT/patches/kuberay"

if [ ! -d "$TARGET/.git" ]; then
  mkdir -p "$ROOT/third_party"
  echo "Cloning KubeRay $UPSTREAM..."
  git clone --depth 1 --branch "$UPSTREAM" https://github.com/ray-project/kuberay.git "$TARGET"
fi

cd "$TARGET"
stamp=".git/applied-patches"
patches=()
if [ -d "$PATCH_DIR" ]; then
  shopt -s nullglob
  patches=("$PATCH_DIR"/*.patch)
  shopt -u nullglob
fi

if [ ${#patches[@]} -eq 0 ]; then
  want=$(printf "%s\n" "$UPSTREAM" | git hash-object --stdin)
else
  want=$( (printf "%s\n" "$UPSTREAM"; cat "${patches[@]}") | git hash-object --stdin)
fi

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
  echo "Patches already applied to third_party/kuberay"
  exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "third_party/kuberay has uncommitted changes; delete it to re-apply" >&2
  exit 1
fi

for p in "${patches[@]}"; do
  echo "Applying patch $(basename "$p")..."
  git apply --whitespace=nowarn "$p"
done

echo "$want" > "$stamp"
echo "KubeRay patches successfully applied."
