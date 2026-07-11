#!/usr/bin/env bash
# Idempotent Android SDK bootstrap for the AVD test rig.
# Pulls cmdline-tools, platform-tools, emulator and a rootable Google-APIs
# x86_64 system image. Safe to re-run; skips what's already there.
#
# Why google_apis (not ..._playstore): Play images lock `adb root`. We need
# root to install the mitmproxy CA as a SYSTEM cert (clean TLS baseline).
# Why API 33 default: last release before the conscrypt-APEX cert move
# (Android 14/API 34), so a system CA drops into /system/etc/security/cacerts
# and is trusted with a plain `-writable-system` remount. No apex bind-mount.
set -euo pipefail

SDK="${ANDROID_SDK_ROOT:-$HOME/Android/sdk}"
API="${API:-33}"
ABI="${ABI:-arm64-v8a}"   # arm64-v8a = REAL aarch64 (TCG on x86, slow but correct);
                          # x86_64 = fast KVM lane (not real arm64).
CLT_ZIP="commandlinetools-linux-9862592_latest.zip"
IMG="system-images;android-${API};google_apis;${ABI}"

# sdkmanager needs a valid JDK. The shell's JAVA_HOME may be stale; pin a good one.
if [ ! -x "${JAVA_HOME:-/nonexistent}/bin/java" ]; then
  for j in java-17-openjdk java-21-openjdk java-17 default; do
    [ -x "/usr/lib/jvm/$j/bin/java" ] && { export JAVA_HOME="/usr/lib/jvm/$j"; break; }
  done
fi
echo "[setup] JAVA_HOME=$JAVA_HOME"

export ANDROID_SDK_ROOT="$SDK" ANDROID_HOME="$SDK"
mkdir -p "$SDK"

if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  echo "[setup] fetching cmdline-tools"
  tmp="$(mktemp -d)"
  curl -fSL "https://dl.google.com/android/repository/$CLT_ZIP" -o "$tmp/clt.zip"
  unzip -q "$tmp/clt.zip" -d "$tmp"
  mkdir -p "$SDK/cmdline-tools"
  rm -rf "$SDK/cmdline-tools/latest"
  mv "$tmp/cmdline-tools" "$SDK/cmdline-tools/latest"
  rm -rf "$tmp"
fi

SDKM="$SDK/cmdline-tools/latest/bin/sdkmanager"
echo "[setup] accepting licenses"
yes | "$SDKM" --licenses >/dev/null 2>&1 || true
echo "[setup] installing platform-tools, emulator, platform + image ($IMG)"
"$SDKM" "platform-tools" "emulator" "platforms;android-${API}" "$IMG"

echo "[setup] done. SDK=$SDK  image=$IMG"
