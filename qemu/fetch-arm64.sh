#!/usr/bin/env bash
# Download the ~1.1 GB LineageOS arm64 prebuilt into the layout qemu/provision.sh
# discovers, and verify it against a pinned SHA256. This is the light path: no
# source build, no 64 GB/400 GiB host. The image is jqssun's published UTM VM
# (github.com/jqssun/android-lineage-qemu); URL, asset name, and hash are pinned
# so the download is reproducible and fails closed on any mismatch or tamper.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qemu/arm64-pin.env
. "$HERE/arm64-pin.env"
TAG="$ARM64_PIN_TAG"
ASSET="$ARM64_PIN_ASSET"
SHA256="$ARM64_PIN_SHA256"
URL="https://github.com/jqssun/android-lineage-qemu/releases/download/$TAG/$ASSET"

BUILD_ROOT="${BUILD_ROOT:-$HOME/Android/lineage-arm64-build}"
DEST="$BUILD_ROOT/dist"

err() { echo "[fetch] ERROR: $*" >&2; exit 2; }
# The arm64 image is pinned, so a TAG argument would be silently misleading.
[ "$#" -eq 0 ] || err "fetch-arm64 takes no arguments (pinned to $TAG); for a different image use the multilib fetch (PROVISION_VARIANT=multilib)"
command -v sha256sum >/dev/null 2>&1 || err "need sha256sum"
command -v curl >/dev/null 2>&1 || err "need curl"

mkdir -p -- "$DEST"
out="$DEST/$ASSET"

# Cached fast path: a previously verified image is byte-identical, so skip the
# multi-GB re-download. Any miss falls through to fetch + verify below.
if [ -f "$out" ] && printf '%s  %s\n' "$SHA256" "$out" | sha256sum -c - >/dev/null 2>&1; then
  echo "[fetch] cached $out already verified; skipping download"
  echo "[fetch] next: lab qemu provision"
  exit 0
fi

echo "[fetch] $ASSET ($TAG)"
curl -fSL --proto '=https' --tlsv1.2 "$URL" -o "$out" || err "download failed: $URL"

printf '%s  %s\n' "$SHA256" "$out" | sha256sum -c - >/dev/null 2>&1 \
  || err "SHA256 mismatch for $ASSET (corrupt or tampered download); expected $SHA256"

echo "[fetch] verified $out"
echo "[fetch] next: lab qemu provision"
