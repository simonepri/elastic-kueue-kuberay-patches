#!/usr/bin/env bash
# Build and publish patched Ray multi-arch image to GHCR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TAG="${RAY_IMAGE_TAG:-2.60.0-patched}"
BASE_IMAGE="${RAY_BASE_IMAGE:-rayproject/ray:2.60.0-py313}"
PLATFORMS="${RAY_PLATFORMS:-linux/amd64,linux/arm64}"
DOCKERFILE="$ROOT/build/ray/Dockerfile"

"$ROOT/build/ray/patch.sh"

wheel_args=()
if [ -n "${RAY_WHEEL_DIR:-}" ]; then
  wheel_args=(--build-context "wheels=$RAY_WHEEL_DIR")
elif [ "${RAY_INSTALL_WHEEL:-0}" = "1" ]; then
  "$ROOT/build/ray/build-wheel.sh"
  wheel_args=(--build-context "wheels=$ROOT/dist/ray")
fi

python_tag="cp${RAY_PYTHON#py}"
build_args=(
  --build-arg BASE_IMAGE="$BASE_IMAGE"
  --build-arg RAY_LOCAL_VERSION="${RAY_LOCAL_VERSION:-${RAY_UPSTREAM}+p${RAY_PATCH_VERSION}}"
  --build-arg RAY_PYTHON_TAG="$python_tag"
  --build-arg RAY_WHEEL_BASE_URL="${RAY_WHEEL_BASE_URL:-https://github.com/simonepri/elastic-kueue-kuberay-patches/releases/download/ray-v${RAY_PATCH_VERSION}}"
)

echo "Publishing Ray image ghcr.io/simonepri/ray:$TAG from $BASE_IMAGE for $PLATFORMS..."
docker buildx build --platform "$PLATFORMS" \
  -f "$DOCKERFILE" \
  "${build_args[@]}" \
  ${wheel_args[@]+"${wheel_args[@]}"} \
  -t "ghcr.io/simonepri/ray:$TAG" \
  --push \
  "$ROOT/third_party/ray"
