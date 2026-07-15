# Native ARM guest-ISA test environment for declaw

Testing declaw properly needs a rooted Android guest that actually executes ARM
app code. The delivered guest supports both AArch64 and AArch32 in one Android
16 boot. On this x86 workstation, QEMU TCG implements that ARM CPU in software;
this does not make the x86 host physical ARM hardware. There is no x86 Android
Native Bridge in the qemu path.

## Why it is hard (first principles)

1. **No hypervisor accelerates a foreign ISA.** Intel VT-x / KVM only accelerate
   x86 guests. arm64 code on an Intel host is binary translation (QEMU TCG),
   software CPU emulation. "Real arm64" and "hardware-fast" cannot both be true on
   x86 silicon. That is a law, not a config we can tune around.
2. **The Android emulator refuses arm64 on x86.** Verified on this box (emulator
   36.6.11): `Avd's CPU Architecture 'arm64' is not supported by the QEMU2
   emulator on x86_64 host`. Google removed arm64-on-x86 TCG from the emulator.

So the only local path to the ARM guest ISA is **upstream
`qemu-system-aarch64` + an ARM multilib Android image**, tuned as hard as TCG
allows. The guest executes the ARM ISA and reports an `aarch64` kernel; the host
still translates those instructions in software.

## The tiers

| Tier | What | ARM execution | Speed | Root | Cost |
|---|---|---|---|---|---|
| **1. Local qemu TCG** (this repo) | qemu-system-aarch64 + LineageOS 23.2 Android 16 `virtio_arm64` multilib | AArch64 + AArch32 guest ISA | TCG, tuned | yes | free |
| **2. Cloud arm64 metal** | c7g/c6g.metal or Ampere bare-metal + Cuttlefish/AVD, KVM | yes | native-fast | yes | ~$2/hr |
| **3. Corellium** | CHARM arm hypervisor, instant root, built-in TLS strip + Frida | yes | native-fast | instant | enterprise |
| x86_64 + ndk-translation | x86_64 AVD (KVM) running arm apps via translation | no (translated) | fast | yes | free |

Tier 1 is the daily driver here. Tier 2 is the escalation when TCG is too slow
for a workload (KVM only shows up on arm *bare-metal*; nested-virt arm VMs do not
expose `/dev/kvm`). Tier 3 is what a funded lab buys.

The x86_64 + translation lane is worth knowing: declaw's **static Flutter patch**
survives ndk-translation (the translator honors the patched .so bytes), so that
one path can be validated at KVM-native speed on an x86_64 image. It does NOT
validate the arm64-only primitives (mempatch, HWBP) or Frida-heavy capture, which
operate on translated code.

## Build and provision the local rig (tier 1)

Run from the repository root so the source tree, pinned builder snapshot, tools,
temporary files, and distribution artifacts stay inside this clone:

```bash
BUILD_ROOT=$PWD/.lineage-multilib-build ./qemu/build-lineage-multilib.sh
BUILD_ROOT=$PWD/.lineage-multilib-build ./lab qemu provision
```

The builder pins the jqssun builder revision, Repo launcher and hash, LineageOS
manifest URL, `lineage-23.2`, product `virtio_arm64`, and `user` variant. Its
distribution directory contains the exact `UTM-VM-*-virtio_arm64.zip`, an OTA,
`build-metadata.txt`, source manifest, and `SHA256SUMS`. Provisioning requires
the metadata to declare `arm64-v8a,armeabi-v7a,armeabi` and `zygote64_32`, checks
the archive and metadata hashes, rejects `arm64only`, patches a staged copy, and
atomically publishes `$HOME/Android/lineage-multilib`. The former arm64-only rig
is not read or overwritten.

The builder enforces the AOSP planning floor of 64 GiB RAM and 400 GiB free
disk. `ALLOW_UNDERSIZED_BUILD=1` is an explicit operator override, not a claim
that a smaller host is reliable. The running rig uses far less space and RAM.

### Speed levers (all verified accepted by qemu 11.0.2, MTTCG confirmed active)

- `-accel tcg,thread=multi`: MTTCG. Confirmed spreading 6 guest vCPUs across 6
  host P-core threads (affinity `0,2,4,6,8,10`). Safe here: the x86 host is
  strongly ordered vs the weakly ordered arm guest (the slow case is the reverse).
- `-cpu max,pauth-impdef=on`: cheap pointer-auth instead of QEMU's slow crypto
  default. Pointer-auth emulation is a big chunk of "aarch64 is 2x slower than an
  x86 guest".
- `-accel ...,tb-size=1024`: 1 GB translation-block cache, less re-translation.
- `taskset -c 0,2,4,6,8,10`: one host P-core thread per vCPU, E-cores left free.
- THP `[always]` backs guest RAM with 2 MB hugepages for free.

### The real "fast" for iteration: snapshot the warm VM

TCG is slow *cold* (first boot runs dex2oat for the world) but fine *warm* (the TB
cache holds the translated ART blocks). So the iteration win is not a faster boot,
it is **not booting again**: after the VM is up + rooted + CA-injected, save a
`savevm` snapshot via the monitor socket and `-loadvm` it in seconds for every
test. Cold boot happens once.

## Root + CA notes (Android 14+)

The system trust store moved into the updatable **conscrypt APEX**
(`/apex/com.android.conscrypt/cacerts`); writing `/system/etc/security/cacerts` no
longer changes trust. `install-ca.sh` rebuilds the cert dir in a tmpfs and
bind-mounts it over both the apex store and the legacy path, then restarts Zygote.
For pinned apps declaw's bypass makes the app accept any cert regardless; the CA
matters only for the clean unpinned baseline.

## Deploy (the `lab` entrypoint)

`lab` gives a pentester one command per backend. The qemu delivery gate is:

```
./lab qemu up
./lab qemu root
./lab qemu check
./lab qemu install --abi arm64-v8a <X.apkm>
./lab qemu install --abi armeabi-v7a <arm32-app.apkm>
./lab qemu accept <arm64-app.apkm> <arm32-app.apkm>
./lab qemu status
./lab qemu down

./lab avd provision    # separate x86_64 Google-APIs/KVM lane
./lab avd up | root | shell | status | down
```

`check` fails closed unless the same live device is Android 16/API 36, rooted,
permissive, `zygote64_32`, exposes both ABI lists, both app-process binaries,
both runtime linkers, and `CONFIG_COMPAT` (or a successful 32-bit linker probe).

`accept` validates each supplied APKM's `info.json`, version, package identity,
native ABI and exact selected splits before device access. It records both
bundle SHA-256 hashes, installs through `shared/install-app.sh` with explicit ABIs,
and verifies installed `versionCode`, `primaryCpuAbi`, and sorted `pm path`
basenames. It resolves the currently enabled launcher instead of assuming an
activity name, uses `am start -W`, and requires two stable observations of the
main PID and executable. the arm64 app must resolve to `/system/bin/app_process64` and
the arm32 app to `/system/bin/app_process32`. Controlled logcat output must contain
no `INSTALL_FAILED_NO_MATCHING_ABIS`, `UnsatisfiedLinkError`, or `CANNOT LINK
EXECUTABLE` result, and the boot ID is checked after each launch and again at the
end.

The acceptance command reinstalls with `-r` and does not uninstall or clear either package,
preserving pentester account state. It force-stops only the app being launched.
A 32-bit process proof is deliberately narrower than TLS instrumentation.
32-bit declaw instrumentation is still a separate limitation because today's
mempatch, HWBP, and mempoke helpers are ARM64-only.

- **qemu backend**: native ARM guest ISA through TCG. Use its ARM64 processes for
  current mempatch / HWBP primitives. Rooting is scripted in `provision.sh` +
  `adb-root.sh`: two 1-byte
  patches (ro.debuggable=1, ro.adb.secure=0) in the ext4 system, plus
  androidboot.selinux=permissive in vendor_boot. No Magisk.
- **avd backend**: x86_64, KVM-fast. Use it for OkHttp / NSC / static-Flutter
  patch testing. arm apps run under ndk-translation; the arm64-native primitives
  do NOT run here.

## Delivery status

- [x] Reproducible `virtio_arm64` multilib build/provision path pins its source
      inputs and records metadata, manifests, and hashes.
- [x] Runtime gate covers Android 16, root, permissive SELinux, `zygote64_32`,
      both ABI lists/runtimes, and kernel compatibility.
- [x] Device-free acceptance tests cover bundle identity/ABI, version and split
      binding, launcher resolution, process executable, linker errors, installer
      failure, missing PID, and changed boot ID.
- [ ] Live release proof remains the final generated-artifact gate: run the two
      supplied production APKMs through `lab qemu accept` after the multilib
      image finishes building.
- [x] The prior local qemu arm64-only rig booted Android 16 with MTTCG across P-cores.
- [x] Root confirmed: `uid=0`, aarch64, Android 16, SELinux Permissive. Boot ~250s.
      Verified declaw-ready: another proc's /proc/pid/mem writable, arm64
      BoringSSL at /apex/com.android.conscrypt/lib64/libssl.so.
- [x] Packaged as `lab` (qemu + avd backends) + `qemu/provision.sh`. Both
      backends verified live: `lab qemu status` -> uid=0 aarch64 Permissive;
      `lab avd status` -> uid=0 Android 13 x86_64. provision patch logic unit-verified.
- [x] ARM64 mempatch decryption was proven separately against a pinned conscrypt app.
      That does not claim support for an ARMv7 target process.
