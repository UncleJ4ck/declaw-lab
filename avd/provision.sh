#!/usr/bin/env bash
# Provision a fresh LineageOS Android 16 virtio_arm64 multilib artifact into a
# rooted, permissive QEMU rig. The older lineage-arm64 rig is intentionally not
# read or modified; this script publishes only to lineage-multilib by default.
set -euo pipefail

DIR="${LINEAGE_DIR:-$HOME/Android/lineage-multilib}"
BUILD_ROOT="${BUILD_ROOT:-$HOME/Android/lineage-multilib-build}"
DRY_RUN="${PROVISION_DRY_RUN:-0}"
UTM_ROOT=LineageOS_on_arm64.utm
CONTRACT='android=16 sdk=36 abis=arm64-v8a,armeabi-v7a,armeabi zygote=zygote64_32'
STAGE=""

error() {
  echo "[provision] ERROR: $*" >&2
  exit 2
}

need() {
  command -v "$1" >/dev/null 2>&1 || error "missing dependency: $1"
}

discover_archive() {
  local candidate newest=""
  local -a candidates=()
  shopt -s nullglob
  candidates=("$BUILD_ROOT"/dist/*-virtio_arm64/UTM-VM-*-virtio_arm64.zip)
  shopt -u nullglob
  ((${#candidates[@]} > 0)) || \
    error "no multilib artifact found under $BUILD_ROOT/dist/*-virtio_arm64"
  for candidate in "${candidates[@]}"; do
    [[ -z $newest || $candidate -nt $newest ]] && newest=$candidate
  done
  printf '%s\n' "$newest"
}

validate_archive_name() {
  local name=${1##*/}
  case "$name" in
    UTM-VM-*-virtio_arm64.zip) ;;
    *) error "artifact must be an exact UTM-VM-*-virtio_arm64.zip multilib build: $name" ;;
  esac
  [[ $name != *arm64only* ]] || error "arm64only artifacts are forbidden: $name"
}

validate_archive_layout() {
  local archive=$1
  python3 - "$archive" "$UTM_ROOT" <<'PY' || exit $?
import pathlib
import stat
import sys
import zipfile

archive = pathlib.Path(sys.argv[1])
root = sys.argv[2]
required = {
    f"{root}/config.plist",
    f"{root}/Data/efi_vars.fd",
    f"{root}/Data/vda.qcow2",
    f"{root}/Data/vdb.qcow2",
}

def reject(message):
    print(f"[provision] ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)

try:
    with zipfile.ZipFile(archive) as bundle:
        infos = bundle.infolist()
        names = [info.filename for info in infos]
except (OSError, zipfile.BadZipFile) as exc:
    reject(f"malformed UTM ZIP: {archive}: {exc}")

normalized_names = {}
for info in infos:
    name = info.filename
    if "\\" in name or "\x00" in name:
        reject(f"unsafe archive path: {name!r}")
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        reject(f"unsafe archive path: {name!r}")
    if path.parts[0] != root:
        reject(f"archive entry is outside {root}: {name}")
    normalized = str(path)
    if normalized in normalized_names:
        reject(
            "archive paths collide after normalization: "
            f"{normalized_names[normalized]!r} and {name!r}"
        )
    normalized_names[normalized] = name
    mode = info.external_attr >> 16
    file_type = stat.S_IFMT(mode)
    if file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
        reject(f"archive special file is not allowed: {name}")

missing = sorted(required.difference(names))
if missing:
    reject("archive is missing required UTM entries: " + ", ".join(missing))

for expected in required:
    info = next(item for item in infos if item.filename == expected)
    if info.is_dir():
        reject(f"required UTM entry is a directory: {expected}")
PY
}

validate_builder_output() {
  local archive=$1 metadata=$2 checksums=$3
  python3 - "$archive" "$metadata" "$checksums" <<'PY'
import hashlib
import pathlib
import re
import sys

archive = pathlib.Path(sys.argv[1])
metadata = pathlib.Path(sys.argv[2])
checksums = pathlib.Path(sys.argv[3])

def reject(message):
    print(f"[provision] ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)

def sha256(path):
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as exc:
        reject(f"cannot read builder output {path}: {exc}")
    return digest.hexdigest()

try:
    metadata_text = metadata.read_text(encoding="utf-8")
except (OSError, UnicodeError) as exc:
    reject(f"cannot read build metadata {metadata}: {exc}")
if "arm64only" in metadata_text:
    reject("build metadata identifies a forbidden arm64only product")

values = {}
for line in metadata_text.splitlines():
    if not line or "=" not in line:
        continue
    key, value = line.split("=", 1)
    values.setdefault(key, []).append(value)
required = {
    "branch": "lineage-23.2",
    "target": "virtio_arm64",
    "variant": "user",
    "abis": "arm64-v8a,armeabi-v7a,armeabi",
    "zygote": "zygote64_32",
}
for key, expected in required.items():
    actual = values.get(key, [])
    if actual != [expected]:
        reject(
            f"build metadata contract mismatch for {key}: "
            f"expected {expected!r}, found {actual!r}"
        )

try:
    checksum_lines = checksums.read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError) as exc:
    reject(f"cannot read SHA256SUMS {checksums}: {exc}")
entries = {}
for number, line in enumerate(checksum_lines, 1):
    match = re.fullmatch(r"([0-9A-Fa-f]{64}) [ *](.+)", line)
    if not match:
        reject(f"malformed SHA256SUMS line {number}")
    digest, name = match.groups()
    entries.setdefault(name, []).append(digest.lower())

expected_hashes = {
    archive.name: sha256(archive),
    "build-metadata.txt": sha256(metadata),
}
for name, expected in expected_hashes.items():
    actual = entries.get(name, [])
    if actual != [expected]:
        reject(
            f"SHA256SUMS must contain exactly one correct hash for {name}: "
            f"expected {expected}, found {actual!r}"
        )
PY
}

patch_vendor_boot() {
  local raw=$1 work=$2 vb_start vb_size vb_image verify_image
  vb_start=$(parted -sm "$raw" unit s print 2>/dev/null | \
    awk -F: '/vendor_boot/{gsub("s","",$2); print $2}')
  vb_size=$(parted -sm "$raw" unit s print 2>/dev/null | \
    awk -F: '/vendor_boot/{gsub("s","",$4); print $4}')
  [[ $vb_start =~ ^[0-9]+$ && $vb_size =~ ^[1-9][0-9]*$ ]] || \
    error "no valid vendor_boot partition found"

  vb_image="$work/.vendor_boot.img"
  verify_image="$work/.vendor_boot.verify.img"
  dd if="$raw" of="$vb_image" bs=512 skip="$vb_start" count="$vb_size" status=none
  python3 - "$vb_image" <<'PY'
import pathlib
import sys

def reject(message):
    print(f"[provision] ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)

path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
if data[:8] != b"VNDRBOOT":
    reject("vendor_boot header is not VNDRBOOT")
offset, size = 28, 2048
raw = bytes(data[offset:offset + size]).split(b"\0", 1)[0]
try:
    current = raw.decode("ascii")
except UnicodeDecodeError as exc:
    reject(f"vendor_boot cmdline is not ASCII: {exc}")

required = ("androidboot.debuggable=1", "androidboot.selinux=permissive")
tokens = current.split()
for key in ("androidboot.debuggable=", "androidboot.selinux="):
    conflicts = [token for token in tokens if token.startswith(key)]
    if conflicts:
        reject(
            f"vendor_boot cmdline is not pristine; found {', '.join(conflicts)}"
        )
updated = (current + (" " if current else "") + " ".join(required)).encode("ascii")
if len(updated) >= size:
    reject("patched vendor_boot cmdline does not fit")
data[offset:offset + size] = updated + b"\0" * (size - len(updated))
path.write_bytes(data)
PY
  dd if="$vb_image" of="$raw" bs=512 seek="$vb_start" count="$vb_size" \
    conv=notrunc status=none

  dd if="$raw" of="$verify_image" bs=512 skip="$vb_start" count="$vb_size" status=none
  python3 - "$verify_image" <<'PY'
import pathlib
import sys

def reject(message):
    print(f"[provision] ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)

data = pathlib.Path(sys.argv[1]).read_bytes()
if data[:8] != b"VNDRBOOT":
    reject("patched vendor_boot header changed")
cmdline = data[28:28 + 2048].split(b"\0", 1)[0].decode("ascii").split()
for token in ("androidboot.debuggable=1", "androidboot.selinux=permissive"):
    if cmdline.count(token) != 1:
        reject(f"vendor_boot postcondition failed for {token}")
PY
  rm -f -- "$vb_image" "$verify_image"
}

patch_system_properties() {
  local raw=$1
  python3 - "$raw" <<'PY'
import mmap
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("r+b") as stream, mmap.mmap(stream.fileno(), 0) as image:
    def count_occurrences(needle):
        count = 0
        cursor = 0
        while True:
            offset = image.find(needle, cursor)
            if offset < 0:
                return count
            count += 1
            cursor = offset + len(needle)

    pairs = (
        (b"ro.debuggable=0", b"ro.debuggable=1"),
        (b"ro.adb.secure=1", b"ro.adb.secure=0"),
    )
    expected = {}
    for source, target in pairs:
        source_count = count_occurrences(source)
        target_count = count_occurrences(target)
        if source_count < 1:
            raise SystemExit(
                f"[provision] ERROR: expected source bytes {source.decode()} were not found"
            )
        expected[target] = target_count + source_count
        cursor = 0
        while True:
            offset = image.find(source, cursor)
            if offset < 0:
                break
            image[offset:offset + len(source)] = target
            cursor = offset + len(target)
    image.flush()
    for source, target in pairs:
        if count_occurrences(source) != 0 or count_occurrences(target) != expected[target]:
            raise SystemExit(
                f"[provision] ERROR: property patch postcondition failed for {target.decode()}"
            )
PY
}

cleanup() {
  if [[ -n $STAGE && -d $STAGE ]]; then
    rm -rf -- "$STAGE"
  fi
}

SOURCE_ARCHIVE="${LINEAGE_MULTILIB_ZIP:-}"
[[ -n $SOURCE_ARCHIVE ]] || SOURCE_ARCHIVE=$(discover_archive)
[[ -f $SOURCE_ARCHIVE ]] || error "artifact not found: $SOURCE_ARCHIVE"
SOURCE_ARCHIVE=$(cd "$(dirname "$SOURCE_ARCHIVE")" && pwd -P)/$(basename "$SOURCE_ARCHIVE")
SOURCE_DIR=$(dirname "$SOURCE_ARCHIVE")
SOURCE_METADATA="${LINEAGE_BUILD_METADATA:-$SOURCE_DIR/build-metadata.txt}"
SOURCE_CHECKSUMS="${LINEAGE_SHA256SUMS:-$SOURCE_DIR/SHA256SUMS}"
[[ -f $SOURCE_METADATA ]] || error "builder metadata not found: $SOURCE_METADATA"
[[ -f $SOURCE_CHECKSUMS ]] || error "builder checksums not found: $SOURCE_CHECKSUMS"
SOURCE_METADATA=$(cd "$(dirname "$SOURCE_METADATA")" && pwd -P)/$(basename "$SOURCE_METADATA")
SOURCE_CHECKSUMS=$(cd "$(dirname "$SOURCE_CHECKSUMS")" && pwd -P)/$(basename "$SOURCE_CHECKSUMS")
ARCHIVE_NAME=$(basename "$SOURCE_ARCHIVE")

need python3
need sha256sum

if [[ $DRY_RUN == 1 ]]; then
  validate_archive_name "$SOURCE_ARCHIVE"
  validate_builder_output "$SOURCE_ARCHIVE" "$SOURCE_METADATA" "$SOURCE_CHECKSUMS"
  validate_archive_layout "$SOURCE_ARCHIVE"
  SOURCE_SHA=$(sha256sum "$SOURCE_ARCHIVE" | awk '{print $1}')
  echo "[provision] source=$SOURCE_ARCHIVE"
  echo "[provision] sha256=$SOURCE_SHA"
  echo "[provision] contract=$CONTRACT"
  echo "[provision] target=$DIR"
  echo "[provision] dry-run: stage ${DIR}.staging.XXXXXX"
  echo "[provision] dry-run: copy ZIP + build-metadata.txt + SHA256SUMS once into protected staging"
  echo "[provision] dry-run: extract $UTM_ROOT with validated safe paths"
  echo "[provision] dry-run: convert $UTM_ROOT/Data/vda.qcow2 -> vda.raw"
  echo "[provision] dry-run: patch staging vendor_boot and Android properties"
  echo "[provision] dry-run: write artifact.sha256 and provenance.txt"
  echo "[provision] dry-run: atomically publish staging -> $DIR"
  exit 0
fi

[[ ! -e $DIR && ! -L $DIR ]] || error "target already exists; refusing to overwrite: $DIR"
for tool in unzip qemu-img parted dd python3 sha256sum awk mktemp cp chmod mv rm rmdir mkdir; do
  need "$tool"
done

mkdir -p -- "$(dirname "$DIR")"
umask 077
STAGE=$(mktemp -d "${DIR}.staging.XXXXXX")
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

INPUT="$STAGE/.input"
mkdir "$INPUT"
cp -- "$SOURCE_ARCHIVE" "$INPUT/$ARCHIVE_NAME"
cp -- "$SOURCE_METADATA" "$INPUT/build-metadata.txt"
cp -- "$SOURCE_CHECKSUMS" "$INPUT/SHA256SUMS"
chmod a-w "$INPUT/$ARCHIVE_NAME" "$INPUT/build-metadata.txt" "$INPUT/SHA256SUMS"
ARCHIVE="$INPUT/$ARCHIVE_NAME"
METADATA="$INPUT/build-metadata.txt"
CHECKSUMS="$INPUT/SHA256SUMS"

validate_archive_name "$ARCHIVE"
validate_builder_output "$ARCHIVE" "$METADATA" "$CHECKSUMS"
validate_archive_layout "$ARCHIVE"
SOURCE_SHA=$(sha256sum "$ARCHIVE" | awk '{print $1}')
echo "[provision] source=$SOURCE_ARCHIVE"
echo "[provision] sha256=$SOURCE_SHA"
echo "[provision] contract=$CONTRACT"
echo "[provision] target=$DIR"

echo "[provision] extracting validated UTM artifact into staging"
unzip -q "$ARCHIVE" -d "$STAGE"
DATA="$STAGE/$UTM_ROOT/Data"
for path in "$STAGE/$UTM_ROOT/config.plist" "$DATA/efi_vars.fd" \
  "$DATA/vda.qcow2" "$DATA/vdb.qcow2"; do
  [[ -f $path ]] || error "extracted layout lost required file: $path"
done

mv -- "$METADATA" "$STAGE/build-metadata.txt"
mv -- "$CHECKSUMS" "$STAGE/SHA256SUMS"
rm -f -- "$ARCHIVE"
rmdir "$INPUT"

echo "[provision] converting vda.qcow2 -> vda.raw"
qemu-img convert -O raw "$DATA/vda.qcow2" "$STAGE/vda.raw"
[[ -s $STAGE/vda.raw ]] || error "qemu-img produced an empty vda.raw"

echo "[provision] patching staged vendor_boot cmdline"
patch_vendor_boot "$STAGE/vda.raw" "$STAGE"
echo "[provision] patching staged ro.debuggable and ro.adb.secure properties"
patch_system_properties "$STAGE/vda.raw"

RAW_SHA=$(sha256sum "$STAGE/vda.raw" | awk '{print $1}')
printf '%s  %s\n' "$SOURCE_SHA" "$ARCHIVE_NAME" >"$STAGE/artifact.sha256"
cat >"$STAGE/provenance.txt" <<EOF
source=$SOURCE_ARCHIVE
source_sha256=$SOURCE_SHA
vda_raw_sha256=$RAW_SHA
contract=$CONTRACT
EOF

[[ ! -e $DIR && ! -L $DIR ]] || error "target appeared during provisioning; refusing to overwrite: $DIR"
mv -T -- "$STAGE" "$DIR"
STAGE=""
trap - EXIT HUP INT TERM
echo "[provision] PASS: published complete multilib rig at $DIR"
echo "[provision] next: avd/lab qemu up && avd/lab qemu check"
