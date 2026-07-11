# Real aarch64 test env for declaw

Testing declaw properly needs a **real arm64 Android with root**. Two walls make
this awkward on an x86 workstation, and this doc records the honest options.

## Why it is hard (first principles)

1. **No hypervisor accelerates a foreign ISA.** Intel VT-x / KVM only accelerate
   x86 guests. arm64 code on an Intel host is binary translation (QEMU TCG),
   software CPU emulation. "Real arm64" and "hardware-fast" cannot both be true on
   x86 silicon. That is a law, not a config we can tune around.
2. **The Android emulator refuses arm64 on x86.** Verified on this box (emulator
   36.6.11): `Avd's CPU Architecture 'arm64' is not supported by the QEMU2
   emulator on x86_64 host`. Google removed arm64-on-x86 TCG from the emulator.

So the only local path to real arm64 is **upstream `qemu-system-aarch64` + an
arm64 Android image**, tuned as hard as TCG allows.

## The tiers

| Tier | What | arm64 real? | Speed | Root | Cost |
|---|---|---|---|---|---|
| **1. Local qemu TCG** (this repo) | qemu-system-aarch64 + LineageOS 23.2 (Android 16) arm64 | yes | TCG, tuned | yes | free |
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

## The local rig (tier 1)

```
avd/setup.sh          # one-time: SDK bits (kept for the x86_64 lane)
avd/boot-arm64.sh     # boot LineageOS arm64 under qemu with the fast-TCG flags
avd/install-ca.sh     # inject the mitmproxy CA into the Android 14+ conscrypt APEX
```

Image: `jqssun/android-lineage-qemu` release `UTM-VM-...virtio_arm64only.zip`
(LineageOS 23.2 = Android 16, non-A/B, 4 GB super). Extract the `.utm` bundle;
`boot-arm64.sh` points at its `Data/` qcow2s and supplies its own 64 MB edk2
pflash (the bundle's 328 KB `efi_vars.fd` is UTM's format, wrong size for qemu).

### Speed levers (all verified accepted by qemu 11.0.2, MTTCG confirmed active)

- `-accel tcg,thread=multi` — MTTCG. Confirmed spreading 6 guest vCPUs across 6
  host P-core threads (affinity `0,2,4,6,8,10`). Safe here: the x86 host is
  strongly ordered vs the weakly ordered arm guest (the slow case is the reverse).
- `-cpu max,pauth-impdef=on` — cheap pointer-auth instead of QEMU's slow crypto
  default. Pointer-auth emulation is a big chunk of "aarch64 is 2x slower than an
  x86 guest".
- `-accel ...,tb-size=1024` — 1 GB translation-block cache, less re-translation.
- `taskset -c 0,2,4,6,8,10` — one host P-core thread per vCPU, E-cores left free.
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

`avd/lab` gives a pentester one command per backend. Pick by what you test:

```
lab qemu provision   # one-time: fetch LineageOS arm64, convert, apply the
                     #           rooted-ready byte patches (permissive + debuggable
                     #           + adb.secure=0). Produces vda.raw.
lab qemu up          # boot headless (fast-TCG). ~4 min first boot.
lab qemu root        # root adb shell: uid=0, aarch64, Permissive
lab qemu ca [pem]    # install a CA (default mitmproxy) for TLS decrypt
lab qemu shell       # adb shell
lab qemu status | down

lab avd provision    # x86_64 Google-APIs image + AVD (KVM, adb-rootable)
lab avd up | root | ca | shell | status | down
```

- **qemu backend**: REAL aarch64. Use it for mempatch / HWBP (the arm64-only
  primitives). Rooting is scripted in `provision.sh` + `adb-root.sh`: two 1-byte
  patches (ro.debuggable=1, ro.adb.secure=0) in the ext4 system, plus
  androidboot.selinux=permissive in vendor_boot. No Magisk.
- **avd backend**: x86_64, KVM-fast. Use it for OkHttp / NSC / static-Flutter
  patch testing. arm apps run under ndk-translation; the arm64-native primitives
  do NOT run here.

## Status

- [x] Local qemu arm64 rig boots real Android 16, MTTCG verified across P-cores.
- [x] Root confirmed: `uid=0`, aarch64, Android 16, SELinux Permissive. Boot ~250s.
      Verified declaw-ready: another proc's /proc/pid/mem writable, arm64
      BoringSSL at /apex/com.android.conscrypt/lib64/libssl.so.
- [x] Packaged as `avd/lab` (qemu + avd backends) + `avd/provision.sh`. Both
      backends verified live: `lab qemu status` -> uid=0 aarch64 Permissive;
      `lab avd status` -> uid=0 Android 13 x86_64. provision patch logic unit-verified.
- [ ] mempatch decryption proof against a native-pinning app (cronet). Needs the
      per-build ssl_verify_peer_cert offset (RE / friTap) + cronet interception.
