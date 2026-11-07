#!/usr/bin/env bash
# Apply patches to upstream Kueue clone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPSTREAM="${KUEUE_UPSTREAM:-v0.20.5}"
TARGET="$ROOT/third_party/kueue"
PATCH_DIR="$ROOT/patches/kueue"

if [ ! -d "$TARGET/.git" ]; then
  mkdir -p "$ROOT/third_party"
  echo "Cloning Kueue $UPSTREAM..."
  git clone --depth 1 --branch "$UPSTREAM" https://github.com/kubernetes-sigs/kueue.git "$TARGET"
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
  echo "Patches already applied to third_party/kueue"
  exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "third_party/kueue has uncommitted changes; delete it to re-apply" >&2
  exit 1
fi

for p in "${patches[@]}"; do
  echo "Applying patch $(basename "$p")..."
  git apply --whitespace=nowarn "$p"
done

echo "$want" > "$stamp"
echo "Kueue patches successfully applied."
