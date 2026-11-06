#!/usr/bin/env bash
# Compile the patched raylet and gcs_server from a Ray checkout with Bazel. Runs inside Ray's manylinux image, or
# directly on a host. Arguments: the checkout, a cache directory and the output directory.

set -euo pipefail

src="$1"
cache="$2"
out="$3"

case "$(uname -m)" in
  x86_64 | amd64) bazel_arch=x86_64 ;;
  aarch64 | arm64) bazel_arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "${HOME:-/tmp/home}"
cd "$src"
version="$(cat .bazelversion)"
name="bazel-$version-linux-$bazel_arch"
bazel="$cache/$name"
if [ ! -x "$bazel" ]; then
  curl -fsSL -o "$bazel.tmp" "https://releases.bazel.build/$version/release/$name"
  curl -fsSL -o "$bazel.sha256" "https://releases.bazel.build/$version/release/$name.sha256"
  echo "$(cut -d' ' -f1 "$bazel.sha256")  $bazel.tmp" | sha256sum -c -
  chmod +x "$bazel.tmp"
  mv "$bazel.tmp" "$bazel"
fi

# Ray's Bazel rules call python3; the manylinux image ships interpreters under /opt/python only.
if [ -d /opt/python/cp310-cp310/bin ]; then
  export PATH="/opt/python/cp310-cp310/bin:$PATH"
  export RAY_BUILD_ENV=manylinux_py3.10
fi

# The disk and repository caches live apart from the output root so CI can keep only them between runs.
"$bazel" --output_user_root="$cache/bazel-root" build --config=ci \
  --disk_cache="$cache/disk" --repository_cache="$cache/repos" \
  //src/ray/gcs:gcs_server //src/ray/raylet:raylet

cp -L bazel-bin/src/ray/gcs/gcs_server "$out/gcs_server"
cp -L bazel-bin/src/ray/raylet/raylet "$out/raylet"
chmod 755 "$out/gcs_server" "$out/raylet"
