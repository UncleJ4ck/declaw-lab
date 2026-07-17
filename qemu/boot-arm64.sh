#!/usr/bin/env bash
# Boot real ARM Android under qemu-system-aarch64 TCG. Both AArch64 and AArch32
# apps execute as ARM guest code; no x86 emulator, KVM, or native bridge is used.
set -euo pipefail

LINEAGE_DIR="${LINEAGE_DIR:-$HOME/Android/lineage-arm64}"
IMG_DIR="${IMG_DIR:-$LINEAGE_DIR/LineageOS_on_arm64.utm/Data}"
RUN="${RUN:-$LINEAGE_DIR/run}"
VDA="${VDA:-$LINEAGE_DIR/vda.raw}"
SMP="${SMP:-6}"
MEM="${MEM:-6144}"
CPU="${CPU:-max,pauth-impdef=on}"
PIN="${PIN:-0,2,4,6,8,10}"
ADB_PORT="${ADB_PORT:-6555}"
CODE="${QEMU_EFI_CODE:-/usr/share/edk2/aarch64/QEMU_EFI.fd}"
VARS="${QEMU_EFI_VARS:-/usr/share/edk2/aarch64/QEMU_VARS.fd}"

cmd=(
  taskset -c "$PIN"
  qemu-system-aarch64
  -name declaw-lineage-arm64
  -machine "virt,gic-version=max"
  -cpu "$CPU"
  -accel "tcg,thread=multi,tb-size=1024"
  -smp "$SMP" -m "$MEM"
  -drive "if=pflash,format=raw,unit=0,file=$RUN/flash_code.fd,readonly=on"
  -drive "if=pflash,format=raw,unit=1,file=$RUN/flash_vars.fd"
  -drive "if=none,id=vda,file=$VDA,format=raw,discard=unmap"
  -device "virtio-blk-pci,drive=vda,bootindex=0"
  -drive "if=none,id=vdb,file=$IMG_DIR/vdb.qcow2,format=qcow2,discard=unmap,detect-zeroes=unmap"
  -device "virtio-blk-pci,drive=vdb,bootindex=1"
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ADB_PORT}-:5555"
  -device "virtio-net-pci,netdev=net0"
  -device virtio-rng-pci
  -device "virtio-gpu-gl-pci,blob=true,hostmem=256M"
  -display "egl-headless,rendernode=/dev/dri/renderD128"
  -serial "file:$RUN/serial.log"
  -monitor "unix:$RUN/mon.sock,server,nowait"
)

if [[ ${DRY_RUN:-0} == 1 ]]; then
  shell_quote() {
    local value=$1
    if [[ $value =~ ^[a-zA-Z0-9_@%+=:,./-]+$ ]]; then
      printf '%s' "$value"
    else
      value=${value//\'/\'\\\'\'}
      printf "'%s'" "$value"
    fi
  }
  printf '[boot] command='
  for argument in "${cmd[@]}"; do
    shell_quote "$argument"
    printf ' '
  done
  printf '\n'
  exit 0
fi

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[boot] ERROR: missing dependency: $1" >&2
    exit 2
  }
}

need taskset
need qemu-system-aarch64
for path in "$CODE" "$VARS" "$VDA" "$IMG_DIR/vdb.qcow2"; do
  [[ -f $path ]] || {
    echo "[boot] ERROR: required file not found: $path" >&2
    exit 2
  }
done

mkdir -p -- "$RUN"
[[ -f $RUN/flash_code.fd ]] || cp -- "$CODE" "$RUN/flash_code.fd"
cp -- "$VARS" "$RUN/flash_vars.fd"
exec "${cmd[@]}"
