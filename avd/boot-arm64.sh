#!/usr/bin/env bash
# Boot the LineageOS arm64 image under upstream qemu-system-aarch64 with the
# fast-TCG flag set. This is the ONLY way to run REAL aarch64 Android on an
# x86_64 host: the Android emulator refuses arm64 on x86, and no hypervisor can
# accelerate a foreign ISA, so it is TCG (software CPU) tuned as hard as it goes.
#
# Speed levers (all verified to be accepted by qemu 11.x):
#   thread=multi   MTTCG: spread guest vCPUs across host cores. Safe here because
#                  the x86 host is strongly-ordered vs the weakly-ordered arm
#                  guest (the pathological case is the reverse).
#   tb-size=1024   1 GB translation-block cache -> less re-translation once warm.
#   pauth-impdef   cheap pointer-auth instead of QEMU's slow crypto default; a
#                  big chunk of "aarch64 is 2x slower than x86 guest" is PAuth.
#   taskset P-core one host P-core thread per vCPU (0,2,4,6,8,10), E-cores left
#                  for the host. THP=always already backs guest RAM with hugepages.
set -euo pipefail

IMG_DIR="${IMG_DIR:-$HOME/Android/lineage-arm64/LineageOS_on_arm64.utm/Data}"
RUN="${RUN:-$HOME/Android/lineage-arm64/run}"
# vda.raw is the disk whose vendor_boot cmdline we patched with
# androidboot.debuggable=1 (enables `adb root`, and keeps adbd OUT of Android 16
# trade-in mode which only triggers when ro.debuggable=0) + selinux=permissive
# (this LineageOS user build honors it; stock user builds would force enforcing).
# Without that patch the graphics stack crash-loops on a udmabuf SELinux denial.
VDA="${VDA:-$HOME/Android/lineage-arm64/vda.raw}"
SMP="${SMP:-6}"
MEM="${MEM:-6144}"
CPU="${CPU:-max,pauth-impdef=on}"     # try neoverse-n1 if max boots slow
PIN="${PIN:-0,2,4,6,8,10}"            # P-core threads on the i7-13620H
# adb host port MUST be outside 5554-5585: that range is adb's emulator scan
# window, and a forward inside it registers a phantom emulator-5554 transport
# that mis-routes shell/sync streams (they close). 6555 avoids it.
ADB_PORT="${ADB_PORT:-6555}"
mkdir -p "$RUN"

# 64 MB pflash banks from edk2-aarch64 (UTM's 328K vars file is the wrong size).
# Fresh writable vars each boot; UEFI finds the image's fallback bootloader.
CODE=/usr/share/edk2/aarch64/QEMU_EFI.fd
[ -f "$RUN/flash_code.fd" ] || cp "$CODE" "$RUN/flash_code.fd"
cp /usr/share/edk2/aarch64/QEMU_VARS.fd "$RUN/flash_vars.fd"

exec taskset -c "$PIN" qemu-system-aarch64 \
  -name declaw-lineage-arm64 \
  -machine virt,gic-version=max \
  -cpu "$CPU" \
  -accel tcg,thread=multi,tb-size=1024 \
  -smp "$SMP" -m "$MEM" \
  -drive if=pflash,format=raw,unit=0,file="$RUN/flash_code.fd",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$RUN/flash_vars.fd" \
  -drive if=none,id=vda,file="$VDA",format=raw,discard=unmap \
  -device virtio-blk-pci,drive=vda,bootindex=0 \
  -drive if=none,id=vdb,file="$IMG_DIR/vdb.qcow2",format=qcow2,discard=unmap,detect-zeroes=unmap \
  -device virtio-blk-pci,drive=vdb,bootindex=1 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${ADB_PORT}-:5555 \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci \
  `# GPU: GL (virgl) variant + blob resources. blob=true is REQUIRED, not optional:` \
  `# without it the image's minigbm gralloc allocates every buffer via /dev/udmabuf,` \
  `# which this LineageOS SELinux policy denies to surfaceflinger, bootanim and all` \
  `# apps (it was built for UTM's Apple-GPU path, so the udmabuf grant is missing).` \
  `# blob=true routes allocation through virtgpu blob resources instead, sidestepping` \
  `# udmabuf entirely so the graphics stack comes up. egl-headless renders offscreen` \
  `# via the host Intel render node, no display server needed.` \
  -device virtio-gpu-gl-pci,blob=true,hostmem=256M \
  -display egl-headless,rendernode=/dev/dri/renderD128 \
  -serial file:"$RUN/serial.log" \
  -monitor unix:"$RUN/mon.sock",server,nowait
