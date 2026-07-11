# declaw-lab

A rooted Android you deploy in one command to test [declaw](https://github.com/UncleJ4ck/declaw):
run a patched app, exercise declaw's arm64 primitives, and watch the decrypted traffic. Two
backends, an interactive window, no cert install on the device.

## Backends: pick your device

```
lab <backend> <command>          # from ./avd/lab
```

| Backend | Device | Speed | Root | Use it for |
|---|---|---|---|---|
| **qemu** | REAL aarch64 Android 16 (qemu-system-aarch64, TCG) | ~4 min boot | uid 0 | declaw's arm64-only primitives: mempatch, HWBP |
| **avd** | x86_64 Android 13 (Google emulator, KVM) | fast | uid 0 | OkHttp / NSC / static-Flutter-patch testing |

The qemu backend is the only one that runs REAL arm64. No hypervisor accelerates a foreign
ISA on an x86 host, so it is a software CPU (TCG) tuned as hard as it goes: MTTCG across the
P-cores, `pauth-impdef`, `virtio-gpu-gl` blob, and byte patches that make it boot rooted and
permissive. See `docs/arm64-testing.md` for the full story.

## Quick start

One-time per backend, fetch and prepare the image:

```bash
cd avd
./lab qemu provision     # real arm64: LineageOS, rooted-ready patches
./lab avd provision      # x86_64: Google-APIs image + AVD
```

Then just name the backend. With no command it boots (if needed), roots, opens the
interactive window, and drops you in a root shell:

```bash
./lab qemu               # -> real aarch64 device, UI window + root shell
./lab avd                # -> x86_64 device, UI window + root shell
./lab                    # -> defaults to qemu
```

The device and window stay up when you leave the shell; `./lab <backend> down` stops it.

Decrypt an app's HTTPS into Burp with one command. Start Burp (its default proxy
listener is enough), then pass the app straight to `lab`:

```bash
./lab ~/app-patched.apk           # boot + install + send its HTTPS to Burp + UI window
./lab com.the.app                 # same for an app already installed
./lab avd ~/app-patched.apk       # same on the x86_64 emulator
```

A bare apk or package is the pentest one-liner: it boots the device if needed, installs
(for an apk), points that app's TLS at a host MITM, and opens the UI window. declaw-patched
(or mempatched) apps accept any cert, so the MITM terminates the TLS, reads the plaintext,
and forwards it into Burp. **There is no device CA to install** (that is the whole point:
declaw is what makes the app accept the cert). Unpatched apps reject it, which is the
negative control.

Burp: point elsewhere with `BURP=host:port ./lab ...`, or `BURP= ./lab ...` to skip Burp
and only write `capture/traffic.log`.

## Commands

Backend is an optional first arg (`qemu` default, or `avd`). Everything folds into the
default, so most sessions are just `lab <apk>`:

```
(nothing)   boot (if needed) + root + UI window + root shell   [the default]
APK | PKG   boot + install (apk) + send that app's HTTPS to Burp + UI   [pentest one-liner]
capture [X] the same, explicit. X = .apk to install, package to scope, or nothing for all apps
probe P L O confirm L@O is the LIVE ssl_verify_peer_cert in pkg P (BRK; you drive 1 request)
provision   one-time: fetch + prepare a rooted-ready image
up root shell ui   the individual steps (all folded into the default)
status      uid / android version / arch / selinux
down        stop (also stops the MITM)
```

## What you bring

- To test declaw's arm64 primitives (mempatch, HWBP): nothing but the `qemu` backend. It is
  a real rooted aarch64 device with BoringSSL loaded, which is exactly what those need.
- To test a patched app end to end: the APK you ran through declaw. `adb install` it on the
  running backend, point capture at it, drive it from the `ui` window.

## Requirements

- Linux x86_64 host, `adb` in PATH.
- qemu backend: `qemu-system-aarch64` (11.x), `edk2-aarch64` firmware, `parted`, `socat`,
  `python3`, `curl`. About 6 GB disk for the image.
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

- `avd/lab` the entrypoint (both backends).
- `avd/provision.sh` fetch + rooted-ready disk prep (qemu).
- `avd/boot-arm64.sh` the tuned qemu-system-aarch64 boot.
- `avd/adb-root.sh` root the running qemu backend.
- `avd/install-ca.sh` install a CA into the Android 14+ conscrypt APEX store.
- `avd/setup.sh` fetch the Android SDK + a system image.
- `docs/arm64-testing.md` why arm64 on x86 is hard, and every wall this rig clears.
