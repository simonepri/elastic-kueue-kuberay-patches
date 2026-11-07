#!/usr/bin/env bash
# Apply patches to upstream Ray sparse checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPSTREAM="${RAY_UPSTREAM:-2.60.0}"
TARGET="$ROOT/third_party/ray"
PATCH_DIR="$ROOT/patches/ray"

patches=()
if [ -d "$PATCH_DIR" ]; then
  shopt -s nullglob
  patches=("$PATCH_DIR"/*.patch)
  shopt -u nullglob
fi

if [ ! -d "$TARGET/.git" ]; then
  mkdir -p "$TARGET"
  echo "Cloning Ray $UPSTREAM sparse files touched by patches/ray..."
  git -C "$TARGET" init -q
  git -C "$TARGET" remote add origin https://github.com/ray-project/ray.git
  if [ ${#patches[@]} -gt 0 ]; then
    git -C "$TARGET" sparse-checkout set --no-cone $(sed -n 's|^+++ b/||p' "${patches[@]}" | sort -u)
  fi
  git -C "$TARGET" fetch -q --depth 1 --filter=blob:none origin tag "ray-$UPSTREAM"
  git -C "$TARGET" checkout -q FETCH_HEAD
fi

cd "$TARGET"
stamp=".git/applied-patches"
if [ ${#patches[@]} -eq 0 ]; then
  want=$(printf "%s\n" "$UPSTREAM" | git hash-object --stdin)
else
  want=$( (printf "%s\n" "$UPSTREAM"; cat "${patches[@]}") | git hash-object --stdin)
fi

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
  echo "Patches already applied to third_party/ray"
  exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "third_party/ray has uncommitted changes; delete it to re-apply" >&2
  exit 1
fi

for p in "${patches[@]}"; do
  echo "Applying patch $(basename "$p")..."
  git apply --whitespace=nowarn "$p"
done

echo "$want" > "$stamp"
echo "Ray patches successfully applied."
