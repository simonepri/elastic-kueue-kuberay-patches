# Patch the stock Ray image: install the patched Ray wheel when RAY_LOCAL_VERSION is set, otherwise overlay the
# patched Python sources from a sparse upstream checkout. The build context is third_party/ray, which holds only the
# files patches/ray touches; the wheel comes from RAY_WHEEL_BASE_URL or from a "wheels" build context.

ARG BASE_IMAGE=rayproject/ray:2.60.0-py313

# Empty unless a build supplies the wheel directory with --build-context wheels=<dir>.
FROM scratch AS wheels

FROM ${BASE_IMAGE}
ARG TARGETARCH
ARG RAY_LOCAL_VERSION=
ARG RAY_PYTHON_TAG=
ARG RAY_WHEEL_BASE_URL=

COPY --chown=1000:100 python/ray/ /tmp/ray-patch/
RUN --mount=type=bind,from=wheels,target=/wheels <<'EOF'
set -eu
if [ -z "$RAY_LOCAL_VERSION" ]; then
  cp -R /tmp/ray-patch/. "$(python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')/ray/"
else
  case "$TARGETARCH" in
    amd64) arch=x86_64 ;;
    arm64) arch=aarch64 ;;
    *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;;
  esac
  name="ray-${RAY_LOCAL_VERSION}-${RAY_PYTHON_TAG}-${RAY_PYTHON_TAG}-manylinux2014_${arch}.whl"
  if [ -n "$RAY_WHEEL_BASE_URL" ]; then
    # The image has no curl, so Python downloads the wheel and its checksum.
    python -c 'import sys, urllib.parse, urllib.request
base, name = sys.argv[1:3]
for suffix in ("", ".sha256"):
    urllib.request.urlretrieve(f"{base}/{urllib.parse.quote(name)}{suffix}", f"/tmp/{name}{suffix}")' \
      "$RAY_WHEEL_BASE_URL" "$name"
    (cd /tmp && sha256sum -c "$name.sha256")
    wheel="/tmp/$name"
  else
    (cd /wheels && sha256sum -c "$name.sha256")
    wheel="/wheels/$name"
  fi
  pip install --no-cache-dir --no-deps --force-reinstall "$wheel"
  rm -f "/tmp/$name" "/tmp/$name.sha256"
fi
rm -rf /tmp/ray-patch
EOF
