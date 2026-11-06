#!/usr/bin/env bash
# Fail if the Ray release stops being a draft until its wheels are uploaded: the release-please config must create the
# release as a draft with its tag, and the wheel workflow must check for a draft, upload, then publish, in that order.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$root/release-please-config.json"
workflow="$root/.github/workflows/ray-wheels.yaml"

jq -e '.packages["patches/ray"] | .draft == true and .["force-tag-creation"] == true' "$config" >/dev/null \
  || { echo "patches/ray must set draft and force-tag-creation in release-please-config.json" >&2; exit 1; }

line() { grep -n -- "$1" "$workflow" | head -1 | cut -d: -f1; }
check="$(line 'name: Require A Draft Release')"
upload="$(line 'gh release upload')"
publish="$(line 'gh release edit .*--draft=false')"
[ -n "$check" ] && [ -n "$upload" ] && [ -n "$publish" ] \
  || { echo "ray-wheels.yaml lacks the draft check, the upload or the publish step" >&2; exit 1; }
[ "$check" -lt "$upload" ] && [ "$upload" -lt "$publish" ] \
  || { echo "ray-wheels.yaml must check for a draft, then upload, then publish" >&2; exit 1; }
echo "ok: the Ray release stays a draft until its assets are uploaded"
