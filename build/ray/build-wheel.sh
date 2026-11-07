#!/usr/bin/env bash
# Build the patched Ray wheel for one CPU architecture: compile the patched raylet and gcs_server, then graft them
# and the patched Python files onto the stock PyPI wheel. Reads RAY_UPSTREAM, RAY_PATCH_VERSION and RAY_PYTHON from
# the environment (mise.toml sets them); RAY_WHEEL_ARCH, RAY_WHEEL_BUILDER, RAY_WHEEL_WORKDIR and RAY_WHEEL_OUT tune it.
# Releases are immutable once published, so the release workflow uploads these wheels to a draft release and
# publishes it afterwards; nothing can be attached to a published release.

set -euo pipefail

: "${RAY_UPSTREAM:?}" "${RAY_PATCH_VERSION:?}" "${RAY_PYTHON:?}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
arch="${RAY_WHEEL_ARCH:-$(uname -m)}"
# "docker" compiles inside Ray's manylinux image so the binaries keep the stock glibc baseline. "host" compiles with
# the host toolchain and only produces a wheel that installs on hosts at least as new as the builder.
builder="${RAY_WHEEL_BUILDER:-docker}"
work="${RAY_WHEEL_WORKDIR:-$repo/.ray-wheel}"
out="${RAY_WHEEL_OUT:-$repo/dist/ray}"
src="$work/ray-$RAY_UPSTREAM"
local_version="$RAY_UPSTREAM+p$RAY_PATCH_VERSION"
python_tag="cp${RAY_PYTHON#py}"

case "$arch" in
  x86_64 | aarch64) ;;
  amd64) arch=x86_64 ;;
  arm64) arch=aarch64 ;;
  *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac

mkdir -p "$work" "$out"

# 1. The upstream tag with the patches applied, redone whenever the patches or the tag change.
want="$RAY_UPSTREAM $(cat "$repo"/patches/ray/*.patch | git hash-object --stdin)"
if [ ! -f "$src/.git/applied-patches" ] || [ "$(cat "$src/.git/applied-patches")" != "$want" ]; then
  rm -rf "$src"
  mkdir -p "$src"
  git -C "$src" init -q
  git -C "$src" remote add origin https://github.com/ray-project/ray.git
  git -C "$src" fetch -q --depth 1 origin tag "ray-$RAY_UPSTREAM"
  git -C "$src" checkout -q FETCH_HEAD
  for patch in "$repo"/patches/ray/*.patch; do
    echo "Applying $patch..."
    git -C "$src" apply --whitespace=nowarn "$patch"
  done
  echo "$want" > "$src/.git/applied-patches"
fi

# 2. The two patched C++ binaries.
bins="$work/bin-$arch"
rm -rf "$bins"
mkdir -p "$bins" "$work/cache-$arch"
if [ "$builder" = docker ]; then
  # The builder image is the one Ray's own wheel builds use.
  image="$(sed -n "s|^FROM quay.io/pypa/manylinux2014_\${HOSTTYPE}:\(.*\)|quay.io/pypa/manylinux2014_$arch:\1|p" \
    "$src/ci/docker/manylinux.Dockerfile")"
  [ -n "$image" ] || { echo "no manylinux image in $src/ci/docker/manylinux.Dockerfile" >&2; exit 1; }
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp/home -e USER=builder \
    -v "$src:/ray" -v "$work/cache-$arch:/cache" -v "$bins:/out" -v "$here:/wheel:ro" \
    -w /ray "$image" bash /wheel/build-binaries.sh /ray /cache /out
elif [ "$builder" = host ]; then
  echo "WARNING: building with the host toolchain; the wheel needs a glibc at least as new as this host's" >&2
  bash "$here/build-binaries.sh" "$src" "$work/cache-$arch" "$bins"
else
  echo "unknown RAY_WHEEL_BUILDER: $builder" >&2
  exit 1
fi

# 3. The wheel: the stock PyPI wheel with the binaries, the patched Python files and the local version swapped in.
python3 -I "$here/assemble-wheel.py" \
  --upstream "$RAY_UPSTREAM" --local-version "$local_version" --python-tag "$python_tag" --arch "$arch" \
  --source "$src" --binaries "$bins" --patches "$repo"/patches/ray/*.patch --out "$out"
