# Native ARM32 + ARM64 Rig Design

## Goal

Upgrade the existing QEMU backend from LineageOS's `virtio_arm64only` product
to its complete `virtio_arm64` product so one Android 16 guest can install and
run both `arm64-v8a` and `armeabi-v7a` applications. The host remains x86_64;
QEMU TCG dynamically translates the guest's ARM instructions to x86_64 while
Android itself remains internally ARM: ARM kernel, ART, Bionic, linkers, JNI,
libraries, and application processes.

This is not a new CPU translator. QEMU TCG is the mature translator already in
the working rig. The current failure is entirely the selected Android product:
`virtio_arm64only` removes the secondary `arm` build and therefore omits the
32-bit Zygote, linker, Bionic libraries, APEX variants, and vendor dependencies.
Changing properties or copying `app_process32` into that disk cannot recreate
the missing dependency closure.

## Image architecture

Build LineageOS 23.2's official `virtio_arm64` target. Its BoardConfig declares
`arm64-v8a` as the primary ABI and `armeabi-v7a,armeabi` as the secondary ABIs;
its product inherits Android's `core_64_bit.mk`, which selects
`zygote64_32`. The shared virtio packaging still emits the same UEFI-compatible
UTM bundle:

```text
LineageOS_on_arm64.utm/Data/vda.qcow2
LineageOS_on_arm64.utm/Data/vdb.qcow2
```

Consequently `boot-arm64.sh` keeps its proven firmware, QEMU machine, graphics,
network, port-forward, and TCG tuning. Provisioning changes only the accepted
artifact target and fails closed if a file named `arm64only` is supplied.

The build is pinned at two levels: the builder implementation commit is fixed,
and each successful source sync writes `repo manifest -r` plus SHA-256 checksums
beside the resulting archive. A later rebuild can consume the recorded manifest
instead of silently following moving Lineage branches.

## User workflow and data flow

`lab qemu provision` consumes a locally built or explicitly supplied
`virtio_arm64` UTM ZIP, converts `vda.qcow2` to the patchable raw disk, applies
the already-proven permissive/debuggable/ADB patches, and preserves the original
archive. `lab qemu up` boots it through `qemu-system-aarch64` and TCG.

Before the rig is considered usable, `lab qemu check` queries one live device
and verifies Android 16/API 36, root, permissive SELinux, `zygote64_32`, both ABI
lists, both app-process binaries, both runtime linkers, and `CONFIG_COMPAT`.
Provisioning never claims success merely because disk conversion completed.

`lab qemu install` accepts a single APK, a directory of split APKs, or an APKM
archive. APKM content is extracted to a temporary directory and only APK entries
are sent to `adb install-multiple`. An optional `--abi arm64-v8a` or
`--abi armeabi-v7a` is forwarded to Package Manager. Mixed ABI split sets must
be selected explicitly; they are never installed ambiguously.

The final acceptance command installs the supplied arm64 and arm32 bundles in
the same boot and proves process architecture, not just properties: the arm64 app must use
`app_process64` with `primaryCpuAbi=arm64-v8a`, while the arm32 app must use
`app_process32` with `primaryCpuAbi=armeabi-v7a`.

## Failure handling

All paths fail closed and print the corrective command. Missing build tools,
insufficient disk, an `arm64only` archive, malformed APKM, empty split set,
unreachable ADB, missing 32-bit runtime files, wrong Zygote mode, enforcing
SELinux, non-root ADB, and Package Manager ABI failures are distinct errors.
Temporary extraction directories are removed by traps. Existing disks are not
overwritten unless their source artifact identity matches; rebuilding uses a
new staging directory and an atomic rename.

The old arm64-only disk is retained as a backup during migration. No destructive
reset or deletion is required to test the new disk.

## Testing and acceptance

Device-free Bash tests place fake `adb`, QEMU, and network commands first in
`PATH`. Any accidental boot/download exits 97. Tests cover the exact multilib
check output, arm64-only rejection, missing runtime components, installer
quoting, APKM filtering, mixed-ABI selection, dry-run build/provision plans, and
dispatch for `check`, `install`, and the pre-existing `keylog` command.

Static gates are `bash -n`, warning-level ShellCheck, and `git diff --check`.
The live gate records the guest boot ID, runs both real APKM bundles without a
reboot, checks each package's `primaryCpuAbi` and process executable, scans for
linker/ABI errors, and records a concise proof log. Only that process-level test
closes the claim that the delivered rig supports both builds.

## Non-goals

This change does not create an x86 Android Native Bridge, claim physical ARM
silicon, or promise that declaw's current ARM64 mempatch/HWBP helpers operate on
a 32-bit target process. It provides the correct multilib Android substrate;
32-bit TLS patching is a separate declaw feature and must be validated after the
ARMv7 process is running.
