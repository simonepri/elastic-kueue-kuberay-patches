#!/usr/bin/env bash
# Build patched Ray container image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="${RAY_IMAGE_TAG:-2.60.0-patched}"
BASE_IMAGE="${RAY_BASE_IMAGE:-rayproject/ray:2.60.0-py313}"
SRC="$ROOT/third_party/ray"
DOCKERFILE="$ROOT/build/ray/Dockerfile"

"$ROOT/build/ray/patch.sh"

wheel_args=()
if [ -n "${RAY_WHEEL_DIR:-}" ]; then
  wheel_args=(--build-context "wheels=$RAY_WHEEL_DIR")
elif [ "${RAY_INSTALL_WHEEL:-0}" = "1" ]; then
  "$ROOT/build/ray/build-wheel.sh"
  wheel_args=(--build-context "wheels=$ROOT/dist/ray")
fi

build_args=(--build-arg BASE_IMAGE="$BASE_IMAGE")
if [ -n "${RAY_LOCAL_VERSION:-}" ] && { [ -n "${RAY_WHEEL_DIR:-}" ] || [ "${RAY_INSTALL_WHEEL:-0}" = "1" ] || [ -n "${RAY_WHEEL_BASE_URL:-}" ]; }; then
  python_tag="cp${RAY_PYTHON#py}"
  build_args+=(
    --build-arg RAY_LOCAL_VERSION="$RAY_LOCAL_VERSION"
    --build-arg RAY_PYTHON_TAG="$python_tag"
    --build-arg RAY_WHEEL_BASE_URL="${RAY_WHEEL_BASE_URL:-}"
  )
fi

echo "Building Ray image: kind.local/ray:$TAG from $BASE_IMAGE..."
docker build -f "$DOCKERFILE" \
  "${build_args[@]}" \
  ${wheel_args[@]+"${wheel_args[@]}"} \
  -t "kind.local/ray:$TAG" \
  -t "kind.local/ray:latest" \
  "$SRC"

echo "kind.local/ray:$TAG" > "$ROOT/.ray-image.txt"
echo "Built Ray image: kind.local/ray:$TAG"
