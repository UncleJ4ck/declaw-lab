# TODO: 32-bit (armeabi-v7a) app support in the rig

Goal: run and decrypt 32-bit-only ARM apps (e.g. a 32-bit armeabi-v7a app) in the
declaw-lab rig, the same way the arm64 path already runs and decrypts an arm64 app.

## Verified landscape (do NOT re-chase these dead ends)

- jqssun/android-lineage-qemu publishes only `virtio_arm64only` prebuilt (64-bit). No prebuilt
  multilib. Confirmed via the GitHub releases API.
- Modern x86_64 emulator image (android-34 google_apis) has NO 32-bit layer: `app_process32`,
  32-bit `libc.so`, and the 32-bit `linker` are all missing; `libndk_translation` carries only an
  `arm64` bridge dir. Overriding `abilist32` does nothing (checked on a booted emulator).
- Modern arm64 emulator image and the Android 16 GSI are 64-bit-only (Pixel 7+ trend).

Conclusion: a MODERN (Android 13+) image that runs 32-bit apps only comes from a source build.

## The chosen path: build once, publish, fetch (no per-pentester build)

- [ ] Produce the multilib image ONCE. Add a disk swapfile (the build preflight now prints the
      exact `fallocate/mkswap/swapon` command; soong needs ~24 GiB resident and zram does not
      count), then run `./avd/build-lineage-multilib.sh` unattended (hours).
- [ ] Publish the artifact set (`UTM-VM-*-virtio_arm64.zip`, `build-metadata.txt`, `SHA256SUMS`)
      as a `declaw-lab` GitHub release.
- [x] `lab qemu fetch [TAG]` downloads + checksum-verifies the release into the layout provision
      expects; `lab qemu provision` then boots it. Pentesters never build.
- [ ] After a real release exists, run `lab qemu fetch && lab qemu provision && lab qemu accept
      <arm64-app.apkm> <arm32-app.apkm>` to prove both ABIs boot in one guest.

## declaw gap for 32-bit decryption (separate from the rig)

- [ ] mempatch is arm64-only: `research/hwbp/hwbp_mempatch.c` hardcodes the AArch64
      `mov w0,#0; ret` stub. Add a 32-bit ARM/Thumb return-0 stub (ARM `mov r0,#0; bx lr` =
      e3a00000 e12fff1e; Thumb `movs r0,#0; bx lr` = 2000 4770) + arch detection from the target
      process/lib. `flutter.py` already has per-arch stubs and `hwbp_keylog` has a 32-bit mode to
      copy from.
- [ ] `find_verify` is AArch64-only (its predicates decode arm64 encodings). A 32-bit conscrypt
      needs an arm32/Thumb finder, or fall back to the `flutter.py` signature scanner / a
      BRK-probe to locate ssl_verify_peer_cert on 32-bit.

## Lighter alternatives to evaluate if the full build stays painful

- [ ] Older Android (API 30 / Android 11-12) arm64 multilib image: 32-bit was not yet removed, so
      an older LineageOS/GSI arm64 build may be multilib AND prebuilt. Verify a downloadable one
      exists and boots under the rig's qemu. Tradeoff: older platform, older conscrypt.
- [ ] Older x86_64 emulator image (API 30, libhoudini/ndk-translation with 32-bit ARM): light KVM
      path for 32-bit apps. Verify one is still installable via sdkmanager. Note: apps run as x86,
      so arm64 mempatch/HWBP do not apply; decrypt via MITM + static patch or friTap instead.
