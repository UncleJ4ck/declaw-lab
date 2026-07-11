#!/usr/bin/env bash
# One-shot: turn the stock LineageOS arm64 QEMU image into a pentester-ready
# rooted rig disk (vda.raw). Idempotent. After this, `arm64 up` + `arm64 root`
# give a rooted aarch64 Android 16 shell for testing declaw's arm64 primitives.
#
# What it does and WHY (each is required, learned the hard way):
#   1. vendor_boot cmdline += androidboot.selinux=permissive
#        The image's minigbm gralloc allocates via /dev/udmabuf, which the stock
#        SELinux policy denies to surfaceflinger/apps -> crash-loop, no boot. This
#        LineageOS build honors permissive from the cmdline, so it boots clean.
#   2. /system build.prop  ro.debuggable=0 -> 1
#        Lets `adb root` run (user-build adbd otherwise drops root) AND keeps adbd
#        out of Android 16 trade-in mode (which blocks shell on unprovisioned VMs).
#   3. /system build.prop  ro.adb.secure=1 -> 0
#        No RSA-auth prompt (there is no GUI to tap "allow"), so adb is "device"
#        not "offline" on fresh /data.
# AVB is `orange` on this image (no vbmeta partition), so nothing verifies these
# edits. They are same-length byte patches, safe on the ext4 system (no verity).
set -euo pipefail

DIR="${LINEAGE_DIR:-$HOME/Android/lineage-arm64}"
VER="${LINEAGE_VER:-v2026.07.09}"
ZIP="UTM-VM-lineage-23.2-20260709-jqssun-virtio_arm64only.zip"
URL="https://github.com/jqssun/android-lineage-qemu/releases/download/${VER}/${ZIP}"
RAW="$DIR/vda.raw"
UTMDATA="$DIR/LineageOS_on_arm64.utm/Data"

need() { command -v "$1" >/dev/null || { echo "[provision] missing dependency: $1"; exit 1; }; }
for t in qemu-img parted unzip curl python3; do need "$t"; done
[ -f /usr/share/edk2/aarch64/QEMU_EFI.fd ] || { echo "[provision] install edk2-aarch64 (QEMU_EFI.fd)"; exit 1; }

mkdir -p "$DIR"; cd "$DIR"

# 1. fetch + unpack the stock image
if [ ! -f "$UTMDATA/vda.qcow2" ]; then
  [ -f "$ZIP" ] || { echo "[provision] downloading $ZIP (~1.1G)"; curl -fSL "$URL" -o "$ZIP"; }
  echo "[provision] unzipping"; unzip -o -q "$ZIP"
fi

# 2. qcow2 -> raw (boot the raw; byte-patchable in place). Skip if already made.
if [ ! -f "$RAW" ]; then
  echo "[provision] converting vda.qcow2 -> vda.raw"
  qemu-img convert -O raw "$UTMDATA/vda.qcow2" "$RAW"
fi

# 3. patch vendor_boot cmdline (permissive from boot)
VB_START=$(parted -sm "$RAW" unit s print 2>/dev/null | awk -F: '/vendor_boot/{gsub("s","",$2);print $2}')
VB_SIZE=$(parted -sm "$RAW" unit s print 2>/dev/null | awk -F: '/vendor_boot/{gsub("s","",$4);print $4}')
[ -n "$VB_START" ] || { echo "[provision] no vendor_boot partition found"; exit 1; }
echo "[provision] patching vendor_boot cmdline (permissive)"
dd if="$RAW" of="$DIR/.vb.img" bs=512 skip="$VB_START" count="$VB_SIZE" status=none
python3 - "$DIR/.vb.img" <<'PY'
import sys
f=sys.argv[1]; d=bytearray(open(f,"rb").read())
assert d[:8]==b"VNDRBOOT", "not a vendor_boot image"
OFF,SIZE=28,2048
cur=d[OFF:OFF+SIZE].split(b"\x00",1)[0].decode()
add=" androidboot.debuggable=1 androidboot.selinux=permissive"
if "androidboot.selinux=permissive" not in cur:
    new=(cur+add).encode(); assert len(new)<SIZE
    d[OFF:OFF+SIZE]=new+b"\x00"*(SIZE-len(new))
    open(f,"wb").write(d); print("  cmdline patched")
else:
    print("  already permissive, skip")
PY
dd if="$DIR/.vb.img" of="$RAW" bs=512 seek="$VB_START" count="$VB_SIZE" conv=notrunc status=none
rm -f "$DIR/.vb.img"

# 4. patch build.prop props (ro.debuggable=1, ro.adb.secure=0) via mmap, in place
echo "[provision] patching ro.debuggable=1 and ro.adb.secure=0"
python3 - "$RAW" <<'PY'
import sys, mmap, re
f=open(sys.argv[1],"r+b"); mm=mmap.mmap(f.fileno(),0)
def flip(find, pos, ch):
    n=0
    for m in re.finditer(re.escape(find), mm):
        i=m.start()+pos
        if mm[i:i+1]!=ch: mm[i:i+1]=ch; n+=1
    return n
a=flip(b"ro.debuggable=0", len("ro.debuggable="), b"1")
b=flip(b"ro.adb.secure=1", len("ro.adb.secure="), b"0")
mm.flush(); mm.close(); f.close()
print(f"  ro.debuggable flipped: {a}   ro.adb.secure flipped: {b}")
PY

echo "[provision] done. Rooted-ready disk: $RAW"
echo "[provision] next: arm64 up   &&   arm64 root"
