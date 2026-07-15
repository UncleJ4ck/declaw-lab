#!/usr/bin/env bash
# Download a published multilib rig release (UTM-VM-*-virtio_arm64.zip + build-metadata.txt +
# SHA256SUMS) into the exact layout qemu/provision.sh discovers, and verify the zip checksum.
# This is the "download, do not build" path: the heavy source build is a one-time producer
# cost; every pentester just fetches the published image and runs `lab qemu provision`.
#
# Usage: fetch-multilib.sh [TAG]      TAG defaults to the latest release.
#   RELEASE_REPO  GitHub owner/repo that publishes the image (default UncleJ4ck/declaw-lab).
#   BUILD_ROOT    where provision looks (default $HOME/Android/lineage-multilib-build).
set -euo pipefail

REPO="${RELEASE_REPO:-UncleJ4ck/declaw-lab}"
BUILD_ROOT="${BUILD_ROOT:-$HOME/Android/lineage-multilib-build}"
TAG="${1:-latest}"

err() { echo "[fetch] ERROR: $*" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || err "need python3"
command -v sha256sum >/dev/null 2>&1 || err "need sha256sum"
command -v curl >/dev/null 2>&1 || err "need curl"

api_path="repos/$REPO/releases/latest"
[ "$TAG" != latest ] && api_path="repos/$REPO/releases/tags/$TAG"

if command -v gh >/dev/null 2>&1; then
  json="$(gh api "$api_path" 2>/dev/null)" || \
    err "no release '$TAG' in $REPO yet. Build the image once (./qemu/build-lineage-multilib.sh) and publish it, then fetch."
else
  json="$(curl -fsSL --proto '=https' --tlsv1.2 "https://api.github.com/$api_path" 2>/dev/null)" || \
    err "no release '$TAG' in $REPO yet (or GitHub API rate-limited). Build+publish the image first, or set RELEASE_REPO."
fi

# Pull tag + the three required asset (name,url) pairs; fail closed if any is missing or the
# zip is an arm64only artifact.
assets="$(printf '%s' "$json" | python3 -c '
import sys, json, re
d = json.load(sys.stdin)
tag = d.get("tag_name", "")
al = d.get("assets", [])
def pick(pred):
    return [a for a in al if pred(a["name"])]
zips = pick(lambda n: re.match(r"UTM-VM-.*-virtio_arm64\.zip$", n) and "arm64only" not in n)
meta = pick(lambda n: n == "build-metadata.txt")
sums = pick(lambda n: n == "SHA256SUMS")
if not zips or not meta or not sums:
    sys.exit("release is missing UTM-VM-*-virtio_arm64.zip / build-metadata.txt / SHA256SUMS")
print(tag)
for a in (zips[0], meta[0], sums[0]):
    print(a["name"] + "\t" + a["browser_download_url"])
')" || err "$assets"

tag="$(printf '%s\n' "$assets" | sed -n '1p')"
[ -n "$tag" ] || err "could not resolve the release tag"
dest="$BUILD_ROOT/dist/${tag}-virtio_arm64"
mkdir -p -- "$dest"

# Cached fast path: a previously verified image is byte-identical, so skip the
# multi-GB re-download. Any miss (no zip, no SHA256SUMS, checksum fail) falls through
# to the normal fetch + verify below, which overwrites a corrupt copy.
cached="$(cd "$dest" && ls UTM-VM-*-virtio_arm64.zip 2>/dev/null | head -1 || true)"
if [ -n "$cached" ] && [ -f "$dest/SHA256SUMS" ] && \
   ( cd "$dest" && awk -v f="$cached" '($2 == f) || ($2 == "*" f) { print }' SHA256SUMS | sha256sum -c - >/dev/null 2>&1 ); then
  echo "[fetch] cached $dest/$cached already verified; skipping download"
  echo "[fetch] next: lab qemu provision"
  exit 0
fi

printf '%s\n' "$assets" | tail -n +2 | while IFS=$'\t' read -r name url; do
  [ -n "$name" ] || continue
  echo "[fetch] $name"
  curl -fSL --proto '=https' --tlsv1.2 "$url" -o "$dest/$name" || err "download failed: $name"
done

zipname="$(cd "$dest" && ls UTM-VM-*-virtio_arm64.zip 2>/dev/null | head -1)"
[ -n "$zipname" ] || err "no UTM-VM-*-virtio_arm64.zip landed in $dest"
( cd "$dest" && awk -v f="$zipname" '($2 == f) || ($2 == "*" f) { print }' SHA256SUMS | sha256sum -c - ) \
  || err "checksum mismatch for $zipname (corrupt or tampered download)"

echo "[fetch] verified $dest/$zipname"
echo "[fetch] next: lab qemu provision"
