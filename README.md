# declaw-lab

A rooted Android lab for testing [declaw](https://github.com/UncleJ4ck/declaw):
run ARM64 and ARM32 production apps in one Android 16 guest, exercise declaw's
ARM64 primitives, and watch decrypted traffic. Two backends, an interactive
window, no cert install on the device.

## Backends: pick your device

```
lab <backend> <command>          # from ./lab
```

| Backend | Device | Speed | Root | Use it for |
|---|---|---|---|---|
| **qemu** | Android 16 `virtio_arm64`, `zygote64_32` (QEMU TCG) | ~4 min boot | uid 0 | Native ARM64 + ARMv7 apps in one guest; ARM64 mempatch/HWBP |
| **avd** | x86_64 Android 13 (Google emulator, KVM) | fast | uid 0 | OkHttp / NSC / static-Flutter-patch testing |

The qemu backend executes the AArch64 and AArch32 guest instruction sets directly
through `qemu-system-aarch64`; it is not an x86 Android image plus Native Bridge.
On an x86 host the CPU implementation is necessarily QEMU TCG software translation,
not physical ARM silicon or KVM. It is tuned with MTTCG, `pauth-impdef`, and a large
translation-block cache. See `docs/arm64-testing.md` for the exact boundary.

## Quick start

The qemu image is a reproducible local LineageOS build. Keep the checkout and all
build work under this clone:

```bash
BUILD_ROOT=$PWD/.lineage-multilib-build ./qemu/build-lineage-multilib.sh
BUILD_ROOT=$PWD/.lineage-multilib-build ./lab qemu provision
./lab avd provision  # separate x86_64 Google-APIs image + AVD
```

The build produces `UTM-VM-*-virtio_arm64.zip`, `build-metadata.txt`, and
`SHA256SUMS` together under `.lineage-multilib-build/dist/`. Provisioning copies
those inputs once, verifies the exact `lineage-23.2` / `virtio_arm64` /
`zygote64_32` contract and both checksums, then atomically publishes the patched
rig at `$HOME/Android/lineage-multilib`. It refuses `virtio_arm64only` and does
not replace an existing rig.

Then just name the backend. With no command it boots (if needed), roots, opens the
interactive window, and drops you in a root shell:

```bash
./lab qemu            # -> ARM multilib guest, UI window + root shell
./lab avd             # -> x86_64 device, UI window + root shell
./lab                 # -> defaults to qemu
```

The device and window stay up when you leave the shell; `./lab <backend> down` stops it.

Decrypt an app's HTTPS into Burp with one command. Start Burp (its default proxy
listener is enough), then pass the app straight to `lab`:

```bash
./lab ~/app-patched.apk           # boot + install + send HTTPS to Burp + UI
./lab com.the.app                 # same for an app already installed
./lab avd ~/app-patched.apk       # same on the x86_64 emulator
```

A bare apk or package is the pentest one-liner: it boots the device if needed, installs
(for an apk), points that app's TLS at a host MITM, and opens the UI window. declaw-patched
(or mempatched) apps accept any cert, so the MITM terminates the TLS, reads the plaintext,
and forwards it into Burp. **There is no device CA to install** (that is the whole point:
declaw is what makes the app accept the cert). Unpatched apps reject it, which is the
negative control.

Burp: point elsewhere with `BURP=host:port ./lab ...`, or
`BURP= ./lab ...` to skip Burp and only write `capture/traffic.log`.

## Commands

Backend is an optional first arg (`qemu` default, or `avd`). Everything folds into the
default, so most sessions are just `lab <apk>`:

```
(nothing)   boot (if needed) + root + UI window + root shell   [the default]
APK | PKG   boot + install (apk) + send that app's HTTPS to Burp + UI   [pentest one-liner]
capture [X] the same, explicit. X = .apk to install, package to scope, or nothing for all apps
check       prove Android 16, zygote64_32, both ABI lists/runtimes, root and CONFIG_COMPAT
install [--abi ABI] APP  capability-check, then install an APK/APKM/XAPK/split directory
accept A B  install and launch an arm64 app and a 32-bit ARM app in the same qemu boot
probe P L O confirm L@O is the LIVE ssl_verify_peer_cert in pkg P (BRK; you drive 1 request)
provision   verify the local multilib build + prepare a rooted-ready image
up root shell ui   the individual steps (all folded into the default)
status      uid / android version / arch / selinux
down        stop (also stops the MITM)
```

## Prove both production app architectures

Run the capability gate first, then install either ABI explicitly when working
with an individual bundle:

```bash
./lab qemu check
./lab qemu install --abi arm64-v8a <arm64-app.apkm>
./lab qemu install --abi armeabi-v7a <arm32-app.apkm>
```

The release gate does both in one boot:

```bash
./lab qemu accept <arm64-app.apkm> <arm32-app.apkm>
```

It validates each APKMirror `info.json`, hashes the bundle, records the exact
selected split names, installs with the production installer, and binds the
installed `versionCode`, `primaryCpuAbi`, and `pm path` split basenames back to
that bundle. It resolves each enabled launcher dynamically, launches with
`am start -W`, then requires a stable main PID whose executable is
`/system/bin/app_process64` for the arm64 app and `/system/bin/app_process32` for the arm32 app.
The boot ID must remain unchanged throughout. The gate only performs reinstall
in place (`-r`); it never uninstalls or clears packages, so existing accounts are
preserved.

## What you bring

- To test declaw's ARM64 primitives (mempatch, HWBP): use the `qemu` backend.
  It is a rooted AArch64 guest with BoringSSL loaded.
- To verify an ARMv7 build installs and launches: use `qemu install --abi
  armeabi-v7a` or the dual-app acceptance gate. Current declaw mempatch/HWBP
  helpers remain ARM64-only; proving the 32-bit process does not imply 32-bit TLS
  instrumentation support.
- To test a patched app end to end: the APK you ran through declaw. `adb install` it on the
  running backend, point capture at it, drive it from the `ui` window.

## Requirements

- Linux x86_64 host, `adb` in PATH.
- Building qemu: the script preflights the AOSP recommendation of 64 GB RAM and
  400 GiB free disk plus all required LineageOS host tools. The generated rig is
  much smaller, but source compilation needs the build capacity.
- Running qemu: `qemu-system-aarch64` (11.x), `edk2-aarch64` firmware,
  `parted`, `socat`, `python3`, and `adb`.
- avd backend: the Android SDK bits are fetched by `lab avd provision` (needs a JDK 17+).
- `ui`: `scrcpy` (a distro package, or the bundled x86_64 prebuilt is fetched on first use).

## How root works (qemu backend)

The image is a LineageOS `user` build, hostile to headless root by default. `provision.sh`
makes it pentester-ready with same-length byte patches on the raw disk (AVB is `orange`, so
nothing verifies them):

- `vendor_boot` cmdline gets `androidboot.selinux=permissive`. Without it the minigbm gralloc
  hits a `/dev/udmabuf` SELinux denial and SurfaceFlinger crash-loops, so it never boots.
- `/system` build.prop `ro.debuggable=0 -> 1` (lets `adb root` run and disables Android 16
  trade-in mode) and `ro.adb.secure=1 -> 0` (no auth prompt, so adb is `device` not `offline`).

Then `adb-root.sh` sets `persist.sys.root_access=3`, restarts adbd, and `adb root` gives uid 0.
No Magisk.

## Files

Two backends, one entrypoint. `qemu/` is the arm64 backend (real aarch64 Android via
`qemu-system-aarch64`), `avd/` is the x86_64 backend (Google emulator), `shared/` is
backend-neutral tooling.

- `lab` the entrypoint (dispatches both backends).
- `qemu/build-lineage-multilib.sh` pinned LineageOS 23.2 `virtio_arm64` build.
- `qemu/provision.sh` verifies the builder sidecars and creates the rooted-ready disk.
- `qemu/fetch-multilib.sh` download + verify a published image (no build).
- `qemu/boot-arm64.sh` the tuned qemu-system-aarch64 boot.
- `qemu/check-multilib.sh` fail-closed live ARM32 + ARM64 runtime gate.
- `qemu/adb-root.sh` root the running qemu backend.
- `avd/setup.sh` fetch the Android SDK + a system image (x86_64 backend).
- `shared/install-app.sh` ABI-aware APK/APKM/XAPK/split installer (both backends).
- `shared/install-ca.sh` install a CA into the Android 14+ conscrypt APEX store.
- `shared/mitm/mitm_fwd.py` host forwarding MITM into Burp.
- `tests/accept_multilib_apps.sh` one-boot arm64 + arm32 process proof.
- `docs/arm64-testing.md` why arm64 on x86 is hard, and every wall this rig clears.
