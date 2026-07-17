# declaw-lab

A rooted Android lab for testing [declaw](https://github.com/UncleJ4ck/declaw):
run production apps on real ARM64 Android 16, exercise declaw's ARM64 primitives
(mempatch, HWBP), and watch decrypted traffic. The default rig is a ~1.1GB
prebuilt image, fetched and rooted in place with no source build. Two backends,
an interactive window, no cert install on the device.

Testing 32-bit (`armeabi-v7a`) apps is an optional add-on: a locally built
multilib rig that runs arm64 and arm32 in one guest. See
[Optional: 32-bit multilib build](#optional-32-bit-multilib-build). Everything
else defaults to the light arm64 path.

## Backends: pick your device

```
lab <backend> <command>          # from ./lab
```

| Backend | Device | Setup | Root | Use it for |
|---|---|---|---|---|
| **qemu** (default) | Android 16 `arm64-v8a` prebuilt (QEMU TCG) | ~1.1GB fetch, no build | uid 0 | declaw's ARM64 primitives: mempatch, HWBP, decrypt |
| **avd** | x86_64 Android 13 (Google emulator, KVM) | SDK image | uid 0 | OkHttp / NSC / static-Flutter-patch testing |

The qemu backend executes the AArch64 guest instruction set directly through
`qemu-system-aarch64` (and AArch32 too on the optional multilib rig); it is not an
x86 Android image plus Native Bridge. On an x86 host the CPU implementation is
necessarily QEMU TCG software translation, not physical ARM silicon or KVM. It is
tuned with MTTCG, `pauth-impdef`, and a large translation-block cache. See
`docs/arm64-testing.md` for the exact boundary.

## Quick start

The default arm64 rig is a pinned prebuilt image, so there is no build step. Fetch
it, root it once, then boot:

```bash
./lab qemu fetch       # download + verify the ~1.1GB arm64 prebuilt (pinned SHA256)
./lab qemu provision   # one-time: root + permissive patch -> ~/Android/lineage-arm64
./lab avd provision    # separate x86_64 Google-APIs image + AVD
```

`fetch` pulls the published LineageOS 23.2 `virtio_arm64only` UTM image and
verifies it against a pinned checksum (fails closed on any mismatch). `provision`
converts the disk, applies the root and permissive patches, and atomically
publishes the rig at `$HOME/Android/lineage-arm64`. It does not replace an existing
rig.

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
fetch       download + verify the arm64 prebuilt (or the multilib image with PROVISION_VARIANT=multilib)
provision   prepare a rooted, permissive rig from the fetched image (one-time)
check       prove the rig: Android 16, root, permissive, arm64-v8a (multilib also checks arm32 + zygote64_32)
install [--abi ABI] APP  capability-check, then install an APK/APKM/XAPK/split directory
probe P L O confirm L@O is the LIVE ssl_verify_peer_cert in pkg P (BRK; you drive 1 request)
accept A B  multilib rig only: install + launch an arm64 app and a 32-bit ARM app in one boot
up root shell ui   the individual steps (all folded into the default)
status      uid / android version / arch / selinux
down        stop (also stops the MITM)
```

## Optional: 32-bit multilib build

You only need this to test `armeabi-v7a` apps. The default arm64 rig runs every
declaw ARM64 primitive without it. No prebuilt multilib image exists, so this path
builds LineageOS from source and is heavy: the builder preflights the AOSP
recommendation of 64 GB RAM and 400 GiB free disk. Build once, then provision the
multilib variant:

```bash
BUILD_ROOT=$PWD/.lineage-multilib-build ./qemu/build-lineage-multilib.sh
BUILD_ROOT=$PWD/.lineage-multilib-build PROVISION_VARIANT=multilib ./lab qemu provision
```

The build produces `UTM-VM-*-virtio_arm64.zip`, `build-metadata.txt`, and
`SHA256SUMS` under `.lineage-multilib-build/dist/`. Provisioning verifies the exact
`lineage-23.2` / `virtio_arm64` / `zygote64_32` contract and both checksums, then
publishes the rig at `$HOME/Android/lineage-multilib`. It refuses `virtio_arm64only`
and does not replace an existing rig. Run the multilib rig by exporting
`PROVISION_VARIANT=multilib` for any `lab qemu` command.

With the multilib rig up, run the capability gate, then install either ABI
explicitly when working with an individual bundle:

```bash
export PROVISION_VARIANT=multilib
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
- The default arm64 rig: `qemu-system-aarch64` (11.x), `edk2-aarch64` firmware,
  `qemu-img`, `parted`, `socat`, `python3`, `curl`, and `adb`. The fetch is ~1.1GB;
  the provisioned rig needs a few GB of disk. No large build capacity.
- Optional multilib build only: the builder preflights 64 GB RAM and 400 GiB free
  disk plus the LineageOS host tools. Skip this unless you need 32-bit apps.
- avd backend: the Android SDK bits are fetched by `lab avd provision` (needs a JDK 17+).
- `ui`: `scrcpy` (a distro package, or the bundled x86_64 prebuilt is fetched on first use).

## How root works (qemu backend)

Both variants share this transform. The image is a LineageOS `user` build, hostile to
headless root by default. `provision.sh` makes it pentester-ready with same-length byte
patches on the raw disk (AVB is `orange`, so nothing verifies them):

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
- `qemu/fetch-arm64.sh` download + verify the arm64 prebuilt against a pinned SHA256 (default).
- `qemu/provision.sh` root + permissive patch into a bootable rig (arm64 default, `PROVISION_VARIANT=multilib`).
- `qemu/boot-arm64.sh` the tuned qemu-system-aarch64 boot.
- `qemu/check-multilib.sh` fail-closed live runtime gate (arm64, or ARM32 + ARM64 for multilib).
- `qemu/adb-root.sh` root the running qemu backend.
- `qemu/build-lineage-multilib.sh` optional: from-source LineageOS 23.2 `virtio_arm64` multilib build.
- `qemu/fetch-multilib.sh` optional: download + verify a published multilib image (no build).
- `avd/setup.sh` fetch the Android SDK + a system image (x86_64 backend).
- `shared/install-app.sh` ABI-aware APK/APKM/XAPK/split installer (both backends).
- `shared/install-ca.sh` install a CA into the Android 14+ conscrypt APEX store.
- `shared/mitm/mitm_fwd.py` host forwarding MITM into Burp.
- `tests/accept_multilib_apps.sh` one-boot arm64 + arm32 process proof.
- `docs/arm64-testing.md` why arm64 on x86 is hard, and every wall this rig clears.
