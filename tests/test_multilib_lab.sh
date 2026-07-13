#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FAKES="$ROOT/tests/fakes"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_line() {
  local output=$1 expected=$2
  grep -Fqx -- "$expected" <<<"$output" || fail "missing exact line: $expected"
}

assert_status() {
  local expected=$1
  shift
  local status
  set +e
  "$@" >/dev/null 2>&1
  status=$?
  set -e
  [[ $status -eq $expected ]] || fail "command returned $status, expected $expected: $*"
}

make_apk() {
  local output=$1
  shift
  python3 - "$output" "$@" <<'PY'
import pathlib
import sys
import zipfile

output = pathlib.Path(sys.argv[1])
output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, "w") as archive:
    archive.writestr("AndroidManifest.xml", b"manifest")
    for entry in sys.argv[2:]:
        archive.writestr(entry, b"fixture")
PY
}

make_bundle() {
  local output=$1 source=$2
  python3 - "$output" "$source" <<'PY'
import pathlib
import sys
import zipfile

output = pathlib.Path(sys.argv[1])
source = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(output, "w") as archive:
    for path in sorted(source.rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(source))
PY
}

make_accept_bundle() {
  local output=$1 package=$2 version_code=$3 version_name=$4 abi=$5
  python3 - "$output" "$package" "$version_code" "$version_name" "$abi" <<'PY'
import io
import json
import pathlib
import sys
import zipfile

output = pathlib.Path(sys.argv[1])
package, version_code, version_name, abi = sys.argv[2:]


def apk(entries):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("AndroidManifest.xml", b"manifest")
        for entry in entries:
            archive.writestr(entry, b"fixture")
    return buffer.getvalue()


output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, "w") as archive:
    archive.writestr(
        "info.json",
        json.dumps(
            {
                "apkm_version": 5,
                "pname": package,
                "versioncode": version_code,
                "release_version": version_name,
                "arches": [abi],
            }
        ),
    )
    if abi == "arm64-v8a":
        archive.writestr("base.apk", apk([]))
        archive.writestr(
            "split_config.arm64_v8a.apk", apk(["lib/arm64-v8a/libfixture.so"])
        )
    elif abi == "armeabi-v7a":
        archive.writestr("base.apk", apk(["lib/armeabi-v7a/libfixture.so"]))
    elif abi == "x86_64":
        archive.writestr("base.apk", apk(["lib/x86_64/libfixture.so"]))
    else:
        raise SystemExit(f"unsupported fixture ABI: {abi}")
    archive.writestr("split_config.en.apk", apk([]))
PY
}

make_utm_archive() {
  local output=$1 mode=${2:-valid}
  python3 - "$output" "$mode" <<'PY'
import pathlib
import stat
import sys
import zipfile

output = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
root = "LineageOS_on_arm64.utm"
entries = {
    f"{root}/config.plist": b"plist",
    f"{root}/Data/efi_vars.fd": b"efi-vars",
    f"{root}/Data/vda.qcow2": b"fake-qcow2",
    f"{root}/Data/vdb.qcow2": b"fake-data-qcow2",
}
if mode == "missing-layout":
    entries.pop(f"{root}/Data/vdb.qcow2")
elif mode == "unsafe":
    entries["../escaped-from-archive"] = b"unsafe"
elif mode == "duplicate-utm":
    entries["Unexpected.utm/config.plist"] = b"unexpected"
elif mode == "top-level-payload":
    entries["operator-payload.txt"] = b"outside the UTM root"
elif mode == "normalized-collision":
    entries[f"{root}/./config.plist"] = b"collides after normalization"

output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, "w") as archive:
    for name, data in entries.items():
        archive.writestr(name, data)
    if mode == "special-fifo":
        fifo = zipfile.ZipInfo(f"{root}/Data/untrusted-fifo")
        fifo.create_system = 3
        fifo.external_attr = (stat.S_IFIFO | 0o644) << 16
        archive.writestr(fifo, b"")
PY
}

make_builder_sidecars() {
  local archive=$1 mode=${2:-valid} directory metadata sums archive_sha metadata_sha
  directory=$(dirname "$archive")
  metadata="$directory/build-metadata.txt"
  sums="$directory/SHA256SUMS"
  cat >"$metadata" <<'EOF'
created_utc=20260713T120000Z
branch=lineage-23.2
target=virtio_arm64
variant=user
abis=arm64-v8a,armeabi-v7a,armeabi
zygote=zygote64_32
EOF
  case "$mode" in
    metadata-arm64only)
      sed -i 's/^target=.*/target=virtio_arm64only/' "$metadata"
      ;;
    metadata-wrong-abi)
      sed -i 's/^abis=.*/abis=arm64-v8a/' "$metadata"
      ;;
  esac
  archive_sha=$(sha256sum "$archive" | awk '{print $1}')
  metadata_sha=$(sha256sum "$metadata" | awk '{print $1}')
  printf '%s  %s\n%s  %s\n' \
    "$archive_sha" "$(basename "$archive")" \
    "$metadata_sha" build-metadata.txt >"$sums"
  case "$mode" in
    wrong-archive-hash)
      sed -i '1s/^[0-9a-f]*/0000000000000000000000000000000000000000000000000000000000000000/' "$sums"
      ;;
    wrong-metadata-hash)
      sed -i '2s/^[0-9a-f]*/0000000000000000000000000000000000000000000000000000000000000000/' "$sums"
      ;;
    duplicate-archive-entry)
      head -n 1 "$sums" >>"$sums"
      ;;
  esac
}

run_checker_profile() {
  local profile=$1 expected_status=$2 adb_timeout=${3:-1} output status
  set +e
  output=$(PATH="$FAKES:$PATH" FAKE_ADB_PROFILE="$profile" \
    CHECK_ADB_TIMEOUT="$adb_timeout" timeout 2 \
    "$ROOT/avd/check-multilib.sh" test-serial 2>&1)
  status=$?
  set -e
  [[ $status -eq $expected_status ]] || {
    printf '%s\n' "$output" >&2
    fail "$profile returned $status, expected $expected_status"
  }
  printf '%s' "$output"
}

test_checker() {
  local output log
  log=$(mktemp)
  trap 'rm -f "$log"' RETURN

  output=$(PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=multilib FAKE_ADB_LOG="$log" \
    "$ROOT/avd/check-multilib.sh" test-serial)
  assert_line "$output" "[check] release=16 sdk=36 kernel=aarch64 uid=0 selinux=Permissive"
  assert_line "$output" "[check] zygote=zygote64_32"
  assert_line "$output" "[check] abilist64=arm64-v8a"
  assert_line "$output" "[check] abilist32=armeabi-v7a,armeabi"
  assert_line "$output" "[check] runtime64=/system/bin/app_process64,/apex/com.android.runtime/bin/linker64"
  assert_line "$output" "[check] runtime32=/system/bin/app_process32,/apex/com.android.runtime/bin/linker"
  assert_line "$output" "[check] compat=CONFIG_COMPAT=y"
  assert_line "$output" "[check] PASS: one Android 16 guest runs arm64-v8a and armeabi-v7a apps"
  if grep -Ev '^-s test-serial( |$)' "$log" | grep -q .; then
    fail "checker made an adb call without the requested serial"
  fi
  if grep -Fq -- " shell sh -c " "$log"; then
    fail "checker used shell sh -c arguments that real adb serializes unsafely"
  fi

  output=$(run_checker_profile arm64only 2)
  assert_line "$output" "[check] FAIL: ro.zygote=zygote64 (need zygote64_32)"
  assert_line "$output" "[check] FAIL: abilist32=<empty> (need armeabi-v7a,armeabi)"
  assert_line "$output" "[check] FAIL: missing executable /system/bin/app_process32"
  assert_line "$output" "[check] FAIL: missing executable /apex/com.android.runtime/bin/linker"
  assert_line "$output" "[check] FAIL: guest does not satisfy the ARM32 + ARM64 Android 16 contract"

  output=$(run_checker_profile missing-runtime 2)
  assert_line "$output" "[check] FAIL: missing executable /system/bin/app_process64"
  assert_line "$output" "[check] FAIL: missing executable /apex/com.android.runtime/bin/linker64"
  assert_line "$output" "[check] FAIL: missing executable /system/bin/app_process32"
  assert_line "$output" "[check] FAIL: missing executable /apex/com.android.runtime/bin/linker"

  output=$(run_checker_profile unreachable 1)
  assert_line "$output" "[check] ERROR: adb device test-serial is unreachable"

  output=$(run_checker_profile disabled-config 2)
  assert_line "$output" "[check] compat=# CONFIG_COMPAT is not set"
  assert_line "$output" "[check] FAIL: CONFIG_COMPAT is disabled (need y)"

  output=$(run_checker_profile unreadable-config 0)
  assert_line "$output" "[check] compat=<unreadable>"
  assert_line "$output" "[check] compat-proof=runtime-probed:/apex/com.android.runtime/bin/linker --help"
  assert_line "$output" "[check] PASS: one Android 16 guest runs arm64-v8a and armeabi-v7a apps"

  output=$(run_checker_profile unreadable-no-probe 2)
  assert_line "$output" "[check] FAIL: CONFIG_COMPAT unavailable and 32-bit runtime probe failed"

  output=$(run_checker_profile collection-failure 1)
  assert_line "$output" "[check] ERROR: adb command failed while reading ro.build.version.release"

  output=$(run_checker_profile hang 1 0.1)
  assert_line "$output" "[check] ERROR: adb command timed out while reading ro.build.version.release"

  echo "PASS: checker"
}

test_installer() {
  local tmp install_log argv_log output status
  tmp=$(mktemp -d)
  install_log="$tmp/install.log"
  argv_log="$tmp/argv.log"
  trap 'rm -rf "$tmp"' RETURN

  make_apk "$tmp/demo.apk"
  PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=installer \
    FAKE_ADB_INSTALL_LOG="$install_log" FAKE_ADB_ARGV_LOG="$argv_log" \
    "$ROOT/avd/install-app.sh" test-serial "$tmp/demo.apk" >/dev/null
  assert_line "$(<"$install_log")" $'install\tdemo.apk'
  grep -Fq -- "$(printf '%q' "$tmp/demo.apk")" "$argv_log" || \
    fail "single APK path was not preserved as one adb argument"

  : >"$install_log"
  : >"$argv_log"
  PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=installer \
    FAKE_ADB_INSTALL_LOG="$install_log" FAKE_ADB_ARGV_LOG="$argv_log" \
    "$ROOT/avd/install-app.sh" test-serial --abi arm64-v8a \
    "$tmp/demo.apk" >/dev/null
  grep -Fq -- "install -r --abi arm64-v8a" "$argv_log" || \
    fail "single APK install did not forward --abi arm64-v8a to adb"

  : >"$install_log"
  mkdir "$tmp/X bundle"
  make_apk "$tmp/X bundle/base.apk"
  make_apk "$tmp/X bundle/feature with spaces.apk"
  make_apk "$tmp/X bundle/split_config.arm64_v8a.apk" \
    lib/arm64-v8a/libfixture.so
  printf 'not an apk\n' >"$tmp/X bundle/read me.txt"
  PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=installer \
    FAKE_ADB_INSTALL_LOG="$install_log" \
    "$ROOT/avd/install-app.sh" test-serial "$tmp/X bundle" >/dev/null
  assert_line "$(<"$install_log")" \
    $'install-multiple\tbase.apk\tfeature with spaces.apk\tsplit_config.arm64_v8a.apk'

  : >"$install_log"
  mkdir "$tmp/instagram-source"
  make_apk "$tmp/instagram-source/base.apk" lib/armeabi-v7a/libinstagram.so
  make_apk "$tmp/instagram-source/split_config.xhdpi.apk"
  make_apk "$tmp/instagram-source/split_config.x86_64.apk"
  printf '{"name":"Instagram"}\n' >"$tmp/instagram-source/info.json"
  make_bundle "$tmp/instagram.apkm" "$tmp/instagram-source"
  PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=installer \
    FAKE_ADB_INSTALL_LOG="$install_log" \
    "$ROOT/avd/install-app.sh" test-serial "$tmp/instagram.apkm" >/dev/null
  assert_line "$(<"$install_log")" \
    $'install-multiple\tbase.apk\tsplit_config.xhdpi.apk'

  : >"$install_log"
  mkdir "$tmp/whatsapp-source"
  make_apk "$tmp/whatsapp-source/com.whatsapp.apk" \
    lib/armeabi-v7a/libwhatsapp.so
  make_apk "$tmp/whatsapp-source/config.armeabi_v7a.apk" \
    lib/armeabi-v7a/libfixture.so
  printf '{"xapk_version":2}\n' >"$tmp/whatsapp-source/manifest.json"
  make_bundle "$tmp/whatsapp.xapk" "$tmp/whatsapp-source"
  PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=installer \
    FAKE_ADB_INSTALL_LOG="$install_log" \
    "$ROOT/avd/install-app.sh" test-serial "$tmp/whatsapp.xapk" >/dev/null
  assert_line "$(<"$install_log")" \
    $'install-multiple\tcom.whatsapp.apk\tconfig.armeabi_v7a.apk'

  : >"$install_log"
  mkdir "$tmp/mixed-source"
  make_apk "$tmp/mixed-source/base.apk"
  make_apk "$tmp/mixed-source/neutral-arm64.apk" \
    lib/arm64-v8a/libneutral.so
  make_apk "$tmp/mixed-source/neutral-arm32.apk" \
    lib/armeabi-v7a/libneutral.so
  make_apk "$tmp/mixed-source/foreign-multi.apk" \
    lib/arm64-v8a/libforeign.so lib/x86_64/libforeign.so
  make_apk "$tmp/mixed-source/split_config.arm64_v8a.apk" \
    lib/arm64-v8a/libfixture.so
  make_apk "$tmp/mixed-source/split_config.armeabi_v7a.apk" \
    lib/armeabi-v7a/libfixture.so
  make_apk "$tmp/mixed-source/split_config.en.apk"
  make_apk "$tmp/mixed-source/split_config.x86.apk"
  make_apk "$tmp/mixed-source/split_config.x86_64.apk" \
    lib/x86_64/libfixture.so
  make_apk "$tmp/mixed-source/universal-native.apk" \
    lib/arm64-v8a/libuniversal.so lib/armeabi-v7a/libuniversal.so
  printf 'metadata\n' >"$tmp/mixed-source/manifest.json"
  make_bundle "$tmp/mixed.apkm" "$tmp/mixed-source"

  set +e
  output=$(PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=installer \
    "$ROOT/avd/install-app.sh" test-serial "$tmp/mixed.apkm" 2>&1)
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "mixed ARM bundle installed without --abi"
  grep -Fq -- "--abi" <<<"$output" || fail "mixed ARM rejection omitted --abi guidance"

  : >"$argv_log"
  PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=installer \
    FAKE_ADB_INSTALL_LOG="$install_log" FAKE_ADB_ARGV_LOG="$argv_log" \
    "$ROOT/avd/install-app.sh" test-serial --abi armeabi-v7a \
    "$tmp/mixed.apkm" >/dev/null
  assert_line "$(<"$install_log")" \
    $'install-multiple\tbase.apk\tneutral-arm32.apk\tsplit_config.armeabi_v7a.apk\tsplit_config.en.apk\tuniversal-native.apk'
  grep -Fq -- "install-multiple -r --abi armeabi-v7a" "$argv_log" || \
    fail "split APK install did not forward --abi armeabi-v7a to adb"
  if grep -Eq 'arm64|x86' "$install_log"; then
    fail "non-selected ARM/x86 ABI split survived armeabi-v7a filtering"
  fi
  if grep -Fq foreign-multi.apk "$install_log"; then
    fail "foreign multi-ABI feature survived armeabi-v7a filtering"
  fi

  : >"$install_log"
  : >"$argv_log"
  PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=installer \
    FAKE_ADB_INSTALL_LOG="$install_log" FAKE_ADB_ARGV_LOG="$argv_log" \
    "$ROOT/avd/install-app.sh" test-serial --abi x86_64 \
    "$tmp/mixed.apkm" >/dev/null
  assert_line "$(<"$install_log")" \
    $'install-multiple\tbase.apk\tforeign-multi.apk\tsplit_config.en.apk\tsplit_config.x86_64.apk'
  grep -Fq -- "install-multiple -r --abi x86_64" "$argv_log" || \
    fail "split APK install did not forward --abi x86_64 to adb"
  if grep -Eq 'arm32|arm64|armeabi|split_config.x86.apk' "$install_log"; then
    fail "non-selected ABI split survived x86_64 filtering"
  fi

  : >"$install_log"
  : >"$argv_log"
  PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=installer \
    FAKE_ADB_INSTALL_LOG="$install_log" FAKE_ADB_ARGV_LOG="$argv_log" \
    "$ROOT/avd/install-app.sh" test-serial --abi x86 \
    "$tmp/mixed.apkm" >/dev/null
  assert_line "$(<"$install_log")" \
    $'install-multiple\tbase.apk\tsplit_config.en.apk\tsplit_config.x86.apk'
  grep -Fq -- "install-multiple -r --abi x86" "$argv_log" || \
    fail "split APK install did not forward --abi x86 to adb"

  mkdir "$tmp/incompatible-base-source"
  make_apk "$tmp/incompatible-base-source/base.apk" \
    lib/arm64-v8a/libbase.so
  make_apk "$tmp/incompatible-base-source/split_config.armeabi_v7a.apk" \
    lib/armeabi-v7a/libselected.so
  make_bundle "$tmp/incompatible-base.apkm" "$tmp/incompatible-base-source"
  set +e
  output=$(PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=installer \
    "$ROOT/avd/install-app.sh" test-serial --abi armeabi-v7a \
    "$tmp/incompatible-base.apkm" 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "incompatible base returned $status, expected 2"
  grep -Fq -- "base.apk" <<<"$output" || \
    fail "incompatible base error omitted base.apk"
  grep -Fq -- "incompatible" <<<"$output" || \
    fail "incompatible base error was not explicit"

  set +e
  output=$(PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=installer \
    "$ROOT/avd/install-app.sh" test-serial --abi armeabi-v7a \
    "$tmp/X bundle" 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "absent requested ABI returned $status, expected 2"
  grep -Fq -- "armeabi-v7a" <<<"$output" || \
    fail "absent requested ABI error omitted the requested ABI"
  grep -Fq -- "not present" <<<"$output" || \
    fail "absent requested ABI error was not explicit"

  mkdir "$tmp/empty-dir"
  printf 'not a zip\n' >"$tmp/malformed.apkm"
  mkdir "$tmp/empty-source"
  printf 'metadata\n' >"$tmp/empty-source/info.json"
  make_bundle "$tmp/empty.apkm" "$tmp/empty-source"
  assert_status 2 "$ROOT/avd/install-app.sh"
  assert_status 2 "$ROOT/avd/install-app.sh" test-serial "$tmp/empty-dir"
  assert_status 2 "$ROOT/avd/install-app.sh" test-serial "$tmp/malformed.apkm"
  assert_status 2 "$ROOT/avd/install-app.sh" test-serial "$tmp/empty.apkm"
  assert_status 2 "$ROOT/avd/install-app.sh" test-serial --abi riscv64 "$tmp/demo.apk"
  assert_status 2 "$ROOT/avd/install-app.sh" test-serial "$tmp/does-not-exist.apkm"

  set +e
  PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=installer FAKE_ADB_FAIL_INSTALL=1 \
    "$ROOT/avd/install-app.sh" test-serial "$tmp/demo.apk" >/dev/null 2>&1
  status=$?
  set -e
  [[ $status -eq 42 ]] || fail "adb install failure returned $status, expected 42"

  echo "PASS: installer"
}

test_acceptance() {
  local tmp x_bundle instagram_bundle wrong_identity wrong_abi wrong_version
  local log install_log boot_calls output status x_sha instagram_sha
  tmp=$(mktemp -d)
  log="$tmp/adb.log"
  install_log="$tmp/install.log"
  boot_calls="$tmp/boot-calls"
  trap 'rm -rf "$tmp"' RETURN

  x_bundle="$tmp/X production bundle.apkm"
  instagram_bundle="$tmp/Instagram production bundle.apkm"
  wrong_identity="$tmp/not X.apkm"
  wrong_abi="$tmp/wrong ABI Instagram.apkm"
  wrong_version="$tmp/wrong X version.apkm"
  make_accept_bundle "$x_bundle" com.twitter.android 312020200 12.2.0-alpha.0 arm64-v8a
  make_accept_bundle "$instagram_bundle" com.instagram.android 383611189 430.0.0.53.80 armeabi-v7a
  make_accept_bundle "$wrong_identity" com.example.notx 312020200 12.2.0-alpha.0 arm64-v8a
  make_accept_bundle "$wrong_abi" com.instagram.android 383611189 430.0.0.53.80 x86_64
  make_accept_bundle "$wrong_version" com.twitter.android 999999999 wrong arm64-v8a
  x_sha=$(sha256sum "$x_bundle" | awk '{print $1}')
  instagram_sha=$(sha256sum "$instagram_bundle" | awk '{print $1}')

  run_acceptance() {
    PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=accept FAKE_ADB_LOG="$log" \
      FAKE_ADB_INSTALL_LOG="$install_log" \
      FAKE_ACCEPT_BOOT_CALLS_FILE="$boot_calls" ACCEPT_POLL_ATTEMPTS=3 \
      ACCEPT_POLL_INTERVAL=0 "$ROOT/tests/accept_multilib_apps.sh" \
      --serial test-serial --x "$x_bundle" --instagram "$instagram_bundle"
  }
  reset_acceptance_logs() {
    : >"$log"
    : >"$install_log"
    : >"$boot_calls"
  }

  assert_status 2 "$ROOT/tests/accept_multilib_apps.sh"
  assert_status 2 "$ROOT/tests/accept_multilib_apps.sh" \
    --serial test-serial --x "$x_bundle"
  assert_status 2 "$ROOT/tests/accept_multilib_apps.sh" \
    --serial test-serial --x "$tmp/missing.apkm" --instagram "$instagram_bundle"

  reset_acceptance_logs
  output=$(run_acceptance)
  assert_line "$output" \
    "[accept] bundle package=com.twitter.android abi=arm64-v8a versionCode=312020200 versionName=12.2.0-alpha.0 sha256=$x_sha splits=base.apk,split_config.arm64_v8a.apk,split_config.en.apk"
  assert_line "$output" \
    "[accept] bundle package=com.instagram.android abi=armeabi-v7a versionCode=383611189 versionName=430.0.0.53.80 sha256=$instagram_sha splits=base.apk,split_config.en.apk"
  assert_line "$output" \
    "[accept] boot_id=11111111-1111-1111-1111-111111111111"
  assert_line "$output" \
    "[accept] PASS package=com.twitter.android abi=arm64-v8a exe=/system/bin/app_process64"
  assert_line "$output" \
    "[accept] PASS package=com.instagram.android abi=armeabi-v7a exe=/system/bin/app_process32"
  assert_line "$output" \
    "[accept] PASS: both architectures launched during the same guest boot"
  [[ $(<"$boot_calls") == 4 ]] || \
    fail "acceptance did not check the baseline, each app, and final boot ID"
  assert_line "$(<"$install_log")" \
    $'install-multiple\tbase.apk\tsplit_config.arm64_v8a.apk\tsplit_config.en.apk'
  assert_line "$(<"$install_log")" \
    $'install-multiple\tbase.apk\tsplit_config.en.apk'
  grep -Fq -- 'install-multiple -r --abi arm64-v8a' "$log" || \
    fail "acceptance did not use the production installer with explicit arm64-v8a"
  grep -Fq -- 'install-multiple -r --abi armeabi-v7a' "$log" || \
    fail "acceptance did not use the production installer with explicit armeabi-v7a"
  grep -Fq -- \
    'cmd package resolve-activity --brief --components --user 0 -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p com.twitter.android' "$log" || \
    fail "acceptance did not dynamically resolve X's enabled launcher"
  grep -Fq -- \
    'cmd package resolve-activity --brief --components --user 0 -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p com.instagram.android' "$log" || \
    fail "acceptance did not dynamically resolve Instagram's enabled launcher"
  grep -Fq -- 'am start -W -n com.twitter.android/.StartActivity' "$log" || \
    fail "acceptance did not launch the resolved X component with -W"
  grep -Fq -- 'am start -W -n com.instagram.android/.MainActivity' "$log" || \
    fail "acceptance did not launch the resolved Instagram component with -W"
  if grep -Eq ' uninstall( |$)| pm clear( |$)| clear-data' "$log"; then
    fail "acceptance cleared or uninstalled account state"
  fi
  if grep -Ev '^-s test-serial( |$)' "$log" | grep -q .; then
    fail "acceptance made an adb call without the selected serial"
  fi

  reset_acceptance_logs
  set +e
  output=$(PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=accept FAKE_ADB_LOG="$log" \
    FAKE_ACCEPT_BOOT_CALLS_FILE="$boot_calls" "$ROOT/tests/accept_multilib_apps.sh" \
    --serial test-serial --x "$wrong_identity" --instagram "$instagram_bundle" 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "wrong X identity returned $status, expected 2"
  grep -Fq -- 'expected package com.twitter.android' <<<"$output" || \
    fail "wrong X identity omitted the semantic package error"
  [[ ! -s $log ]] || fail "wrong X identity accessed adb before local validation"

  reset_acceptance_logs
  set +e
  output=$(PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=accept FAKE_ADB_LOG="$log" \
    FAKE_ACCEPT_BOOT_CALLS_FILE="$boot_calls" "$ROOT/tests/accept_multilib_apps.sh" \
    --serial test-serial --x "$x_bundle" --instagram "$wrong_abi" 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "wrong Instagram ABI returned $status, expected 2"
  grep -Fq -- 'does not contain native ABI armeabi-v7a' <<<"$output" || \
    fail "wrong Instagram ABI omitted the native-ABI error"
  [[ ! -s $log ]] || fail "wrong Instagram ABI accessed adb before local validation"

  reset_acceptance_logs
  set +e
  output=$(PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=accept FAKE_ADB_LOG="$log" \
    FAKE_ADB_INSTALL_LOG="$install_log" FAKE_ACCEPT_BOOT_CALLS_FILE="$boot_calls" \
    ACCEPT_POLL_INTERVAL=0 "$ROOT/tests/accept_multilib_apps.sh" \
    --serial test-serial --x "$wrong_version" --instagram "$instagram_bundle" 2>&1)
  status=$?
  set -e
  [[ $status -eq 1 ]] || fail "installed version mismatch returned $status, expected 1"
  grep -Fq -- 'versionCode=312020200 (expected 999999999)' <<<"$output" || \
    fail "installed version mismatch omitted expected and actual versions"

  reset_acceptance_logs
  set +e
  output=$(FAKE_ACCEPT_X_SPLITS='base.apk,split_config.en.apk' run_acceptance 2>&1)
  status=$?
  set -e
  [[ $status -eq 1 ]] || fail "installed split mismatch returned $status, expected 1"
  grep -Fq -- 'installed splits do not match supplied bundle' <<<"$output" || \
    fail "installed split mismatch omitted a useful error"

  reset_acceptance_logs
  set +e
  output=$(FAKE_ACCEPT_INSTAGRAM_EXE=/system/bin/app_process64 run_acceptance 2>&1)
  status=$?
  set -e
  [[ $status -eq 1 ]] || fail "wrong process executable returned $status, expected 1"
  grep -Fq -- 'exe=/system/bin/app_process64 (expected /system/bin/app_process32)' <<<"$output" || \
    fail "wrong process executable omitted actual and expected paths"

  reset_acceptance_logs
  set +e
  output=$(FAKE_ACCEPT_LOGCAT='E/linker: CANNOT LINK EXECUTABLE libbroken.so' \
    run_acceptance 2>&1)
  status=$?
  set -e
  [[ $status -eq 1 ]] || fail "linker error returned $status, expected 1"
  grep -Fq -- 'CANNOT LINK EXECUTABLE' <<<"$output" || \
    fail "linker failure omitted the triggering log line"

  reset_acceptance_logs
  set +e
  output=$(FAKE_ACCEPT_CHANGE_BOOT_AFTER=1 run_acceptance 2>&1)
  status=$?
  set -e
  [[ $status -eq 1 ]] || fail "changed boot ID returned $status, expected 1"
  grep -Fq -- 'guest boot ID changed' <<<"$output" || \
    fail "changed boot ID omitted a useful error"

  reset_acceptance_logs
  set +e
  output=$(FAKE_ADB_FAIL_INSTALL=1 run_acceptance 2>&1)
  status=$?
  set -e
  [[ $status -eq 42 ]] || fail "acceptance installer failure returned $status, expected 42"
  grep -Fq -- '[install] ERROR: adb install failed with status 42' <<<"$output" || \
    fail "acceptance masked the production installer failure"

  reset_acceptance_logs
  set +e
  output=$(FAKE_ACCEPT_MISSING_PID=com.twitter.android run_acceptance 2>&1)
  status=$?
  set -e
  [[ $status -eq 1 ]] || fail "missing main PID returned $status, expected 1"
  grep -Fq -- 'stable main PID not found for com.twitter.android' <<<"$output" || \
    fail "missing PID omitted a useful process error"

  grep -Fq -- \
    'BUILD_ROOT=$PWD/.lineage-multilib-build ./avd/build-lineage-multilib.sh' \
    "$ROOT/README.md" || fail "README omitted the clone-local multilib build command"
  grep -Fq -- './avd/lab qemu check' "$ROOT/README.md" || \
    fail "README omitted the live multilib gate"
  grep -Fq -- './avd/lab qemu install --abi armeabi-v7a' "$ROOT/README.md" || \
    fail "README omitted explicit ARM32 installation"
  grep -Fq -- './avd/lab qemu accept <X.apkm> <Instagram.apkm>' "$ROOT/README.md" || \
    fail "README omitted the one-boot acceptance command"
  grep -Fq -- 'build-metadata.txt' "$ROOT/README.md" || \
    fail "README omitted builder provenance metadata"
  grep -Fq -- 'SHA256SUMS' "$ROOT/README.md" || \
    fail "README omitted builder checksums"
  grep -Fq -- 'does not make the x86 host physical ARM hardware' \
    "$ROOT/docs/arm64-testing.md" || \
    fail "architecture documentation blurred guest ARM ISA and host hardware"
  grep -Fq -- 'does not uninstall or clear either package' \
    "$ROOT/docs/arm64-testing.md" || \
    fail "acceptance documentation omitted account preservation"
  grep -Fq -- '32-bit declaw instrumentation is still a separate limitation' \
    "$ROOT/docs/arm64-testing.md" || \
    fail "documentation omitted the current 32-bit declaw limitation"

  echo "PASS: acceptance"
}

make_dispatch_fakes() {
  local bin=$1
  mkdir -p "$bin"
  python3 - "$bin" <<'PY'
import pathlib
import sys

bin_dir = pathlib.Path(sys.argv[1])
scripts = {
    "adb": r'''#!/usr/bin/env bash
set -u
if [[ -n ${FAKE_LAB_COMMAND_LOG:-} ]]; then
  { printf 'adb'; printf '\t%q' "$@"; printf '\n'; } >>"$FAKE_LAB_COMMAND_LOG"
fi
if [[ ${FAKE_FORBID_ADB:-0} == 1 ]]; then
  echo "fake adb: device access was not allowed" >&2
  exit 97
fi
if [[ ${1:-} == -s && ${3:-} == get-state ]]; then
  if [[ ${FAKE_ADB_PROFILE:-} == status-hang ]]; then
    /usr/bin/sleep 5
    exit 0
  fi
  if [[ ${FAKE_ADB_PROFILE:-} != unreachable ]]; then
    echo device
    exit 0
  fi
fi
case "${1:-}:${2:-}:${3:-}:${4:-}:${5:-}" in
  devices::::) printf 'List of devices attached\nemulator-5554\tdevice\n'; exit 0 ;;
  connect:*) echo "connected to ${2:-}"; exit 0 ;;
  -s:*:shell:getprop:sys.boot_completed) echo 1; exit 0 ;;
  -s:*:shell:echo:OK) echo OK; exit 0 ;;
  -s:*:root:*) echo "restarting adbd as root"; exit 0 ;;
  -s:*:wait-for-device:*) exit 0 ;;
  -s:*:remount:*) exit 0 ;;
esac
if [[ ${1:-} == -s && ${3:-} == shell ]]; then
  remote="${*:4}"
  case "$remote" in
    "setprop persist.sys.root_access 3; setprop service.adb.root 1; setprop ctl.restart adbd") exit 0 ;;
    id) echo 'uid=0(root) gid=0(root)'; exit 0 ;;
    "iptables -t nat -L OUTPUT -n") exit 0 ;;
  esac
fi
exec "$REAL_FAKE_ADB" "$@"
''',
    "pgrep": r'''#!/usr/bin/env bash
if [[ -n ${FAKE_LAB_COMMAND_LOG:-} ]]; then
  { printf 'pgrep'; printf '\t%q' "$@"; printf '\n'; } >>"$FAKE_LAB_COMMAND_LOG"
fi
if [[ ${FAKE_FORBID_PGREP:-0} == 1 ]]; then
  echo "fake pgrep: qemu inspection was not allowed" >&2
  exit 97
fi
[[ ${FAKE_PGREP_RESULT:-hit} != miss ]]
exit $?
''',
    "sleep": "#!/usr/bin/env bash\nexit 0\n",
    "scrcpy": r'''#!/usr/bin/env bash
[[ -z ${FAKE_LAB_COMMAND_LOG:-} ]] || printf 'scrcpy\n' >>"$FAKE_LAB_COMMAND_LOG"
exit 0
''',
    "declaw": r'''#!/usr/bin/env bash
{ printf 'declaw'; printf '\t%q' "$@"; printf '\n'; } >>"$FAKE_LAB_COMMAND_LOG"
exit 0
''',
    "curl": r'''#!/usr/bin/env bash
[[ -z ${FAKE_LAB_COMMAND_LOG:-} ]] || printf 'curl\n' >>"$FAKE_LAB_COMMAND_LOG"
echo 'fake curl: network forbidden' >&2
exit 97
''',
    "qemu-system-aarch64": r'''#!/usr/bin/env bash
[[ -z ${FAKE_LAB_COMMAND_LOG:-} ]] || printf 'qemu-system-aarch64\n' >>"$FAKE_LAB_COMMAND_LOG"
echo 'fake qemu: boot forbidden' >&2
exit 97
''',
    "nohup": r'''#!/usr/bin/env bash
if [[ -n ${FAKE_LAB_COMMAND_LOG:-} ]]; then
  printf 'nohup\tLINEAGE_DIR=%q' "${LINEAGE_DIR:-<unset>}" >>"$FAKE_LAB_COMMAND_LOG"
  printf '\t%q' "$@" >>"$FAKE_LAB_COMMAND_LOG"
  printf '\n' >>"$FAKE_LAB_COMMAND_LOG"
fi
exit 0
''',
    "emulator": r'''#!/usr/bin/env bash
if [[ ${1:-} == -list-avds ]]; then
  echo declaw_x86_64
  exit 0
fi
echo 'fake emulator: boot forbidden' >&2
exit 97
''',
}
for name, body in scripts.items():
    path = bin_dir / name
    path.write_text(body)
    path.chmod(0o755)
PY
}

run_lab() {
  local home=$1 bin=$2
  shift 2
  HOME="$home" ANDROID_SDK_ROOT="$home/empty-sdk" \
    PATH="$bin:$FAKES:$PATH" REAL_FAKE_ADB="$FAKES/adb" \
    FAKE_ADB_PROFILE="${FAKE_ADB_PROFILE:-multilib}" \
    "$ROOT/avd/lab" "$@"
}

test_dispatch() {
  local tmp home bin log argv_log install_log output status check_line install_line path
  local x_bundle instagram_bundle boot_calls
  tmp=$(mktemp -d)
  home="$tmp/home"
  bin="$tmp/bin"
  log="$tmp/commands.log"
  argv_log="$tmp/argv.log"
  install_log="$tmp/install.log"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$home/Android/lineage-multilib" "$home/empty-sdk"
  : >"$home/Android/lineage-multilib/vda.raw"
  : >"$log"
  : >"$argv_log"
  : >"$install_log"
  make_dispatch_fakes "$bin"

  assert_qemu_install_preflight_rejects() {
    local expected=$1
    shift
    : >"$log"
    set +e
    output=$(FAKE_LAB_COMMAND_LOG="$log" FAKE_FORBID_ADB=1 \
      FAKE_FORBID_PGREP=1 run_lab "$home" "$bin" qemu install "$@" 2>&1)
    status=$?
    set -e
    [[ $status -eq 2 ]] || {
      printf '%s\n' "$output" >&2
      fail "invalid qemu install returned $status, expected 2: $*"
    }
    grep -Fq -- "$expected" <<<"$output" || {
      printf '%s\n' "$output" >&2
      fail "invalid qemu install omitted useful error '$expected': $*"
    }
    [[ ! -s $log ]] || {
      printf '%s\n' "$(<"$log")" >&2
      fail "invalid qemu install accessed a process or device before local validation: $*"
    }
  }

  # `check` is an inspection-only command: it must work with no image and must
  # neither inspect the host qemu process nor enter the boot/download paths.
  rm -f "$home/Android/lineage-multilib/vda.raw"
  output=$(FAKE_FORBID_PGREP=1 FAKE_LAB_COMMAND_LOG="$log" \
    run_lab "$home" "$bin" qemu check)
  assert_line "$output" "[check] PASS: one Android 16 guest runs arm64-v8a and armeabi-v7a apps"
  if grep -Eq 'curl|qemu-system-aarch64' "$log"; then
    fail "qemu check attempted a download or boot"
  fi
  set +e
  output=$(FAKE_FORBID_PGREP=1 FAKE_ADB_PROFILE=arm64only \
    run_lab "$home" "$bin" qemu check 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "qemu check returned $status instead of checker status 2"
  assert_line "$output" "[check] FAIL: guest does not satisfy the ARM32 + ARM64 Android 16 contract"

  : >"$home/Android/lineage-multilib/vda.raw"
  : >"$log"
  make_apk "$tmp/demo app.apk" lib/arm64-v8a/libdemo.so
  x_bundle="$tmp/X dispatch.apkm"
  instagram_bundle="$tmp/Instagram dispatch.apkm"
  boot_calls="$tmp/dispatch-boot-calls"
  make_accept_bundle "$x_bundle" com.twitter.android 312020200 12.2.0-alpha.0 arm64-v8a
  make_accept_bundle "$instagram_bundle" com.instagram.android 383611189 430.0.0.53.80 armeabi-v7a
  assert_qemu_install_preflight_rejects \
    "usage: lab qemu install [--abi arm64-v8a|armeabi-v7a] APP"
  assert_qemu_install_preflight_rejects \
    "[install] ERROR: app path not found: $tmp/missing.apk" \
    "$tmp/missing.apk"
  assert_qemu_install_preflight_rejects \
    "[install] ERROR: expected exactly one APP path" \
    "$tmp/demo app.apk" extra
  assert_qemu_install_preflight_rejects \
    "[install] ERROR: --abi requires a value and APP path" \
    --abi
  assert_qemu_install_preflight_rejects \
    "[install] ERROR: unsupported qemu ABI x86_64 (expected arm64-v8a or armeabi-v7a)" \
    --abi x86_64 "$tmp/demo app.apk"

  FAKE_LAB_COMMAND_LOG="$log" FAKE_ADB_LOG="$log" \
    FAKE_ADB_ARGV_LOG="$argv_log" FAKE_ADB_INSTALL_LOG="$install_log" \
    run_lab "$home" "$bin" qemu install --abi arm64-v8a "$tmp/demo app.apk" >/dev/null
  grep -Fq -- "install -r --abi arm64-v8a" "$argv_log" || \
    fail "lab install did not preserve --abi for install-app.sh"
  grep -Fq -- "$(printf '%q' "$tmp/demo app.apk")" "$argv_log" || \
    fail "lab install did not preserve an app path containing spaces"
  check_line=$(grep -nF 'getprop ro.zygote' "$log" | tail -1 | cut -d: -f1)
  install_line=$(grep -n $' install ' "$log" | tail -1 | cut -d: -f1)
  [[ -n $check_line && -n $install_line && $check_line -lt $install_line ]] || \
    fail "lab install did not check multilib capability before adb install"

  : >"$install_log"
  set +e
  FAKE_ADB_PROFILE=arm64only FAKE_ADB_INSTALL_LOG="$install_log" \
    run_lab "$home" "$bin" qemu install "$tmp/demo app.apk" >/dev/null 2>&1
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "lab install on arm64-only guest returned $status, expected 2"
  [[ ! -s $install_log ]] || fail "lab install called adb after the multilib check failed"

  : >"$log"
  set +e
  output=$(FAKE_LAB_COMMAND_LOG="$log" FAKE_FORBID_ADB=1 \
    FAKE_FORBID_PGREP=1 run_lab "$home" "$bin" qemu accept 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "qemu accept without bundles returned $status, expected 2"
  grep -Fq -- 'usage: lab qemu accept X.apkm INSTAGRAM.apkm' <<<"$output" || \
    fail "qemu accept without bundles omitted usage"
  [[ ! -s $log ]] || fail "invalid qemu accept accessed a process or device"

  : >"$log"
  set +e
  output=$(FAKE_LAB_COMMAND_LOG="$log" FAKE_FORBID_ADB=1 \
    FAKE_FORBID_PGREP=1 run_lab "$home" "$bin" qemu accept \
    "$tmp/missing.apkm" "$instagram_bundle" 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "qemu accept missing X bundle returned $status, expected 2"
  grep -Fq -- "bundle not found: $tmp/missing.apkm" <<<"$output" || \
    fail "qemu accept missing X bundle omitted its path"
  [[ ! -s $log ]] || fail "missing qemu accept bundle accessed a process or device"

  : >"$log"
  : >"$install_log"
  : >"$boot_calls"
  output=$(FAKE_ADB_PROFILE=accept FAKE_LAB_COMMAND_LOG="$log" \
    FAKE_ADB_LOG="$log" FAKE_ADB_INSTALL_LOG="$install_log" \
    FAKE_ACCEPT_BOOT_CALLS_FILE="$boot_calls" ACCEPT_POLL_ATTEMPTS=3 \
    ACCEPT_POLL_INTERVAL=0 run_lab "$home" "$bin" qemu accept \
    "$x_bundle" "$instagram_bundle")
  assert_line "$output" \
    "[accept] PASS package=com.twitter.android abi=arm64-v8a exe=/system/bin/app_process64"
  assert_line "$output" \
    "[accept] PASS package=com.instagram.android abi=armeabi-v7a exe=/system/bin/app_process32"
  assert_line "$output" \
    "[accept] PASS: both architectures launched during the same guest boot"

  : >"$log"
  set +e
  output=$(FAKE_LAB_COMMAND_LOG="$log" FAKE_FORBID_ADB=1 \
    FAKE_FORBID_PGREP=1 run_lab "$home" "$bin" avd accept \
    "$x_bundle" "$instagram_bundle" 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "avd accept returned $status, expected 2"
  grep -Fq -- '[accept] qemu-only: the AVD guest is x86_64' <<<"$output" || \
    fail "avd accept did not explain the qemu-only architecture proof"
  [[ ! -s $log ]] || fail "avd accept accessed a process or device"

  : >"$log"
  FAKE_PGREP_RESULT=miss FAKE_LAB_COMMAND_LOG="$log" \
    run_lab "$home" "$bin" qemu up >/dev/null
  for _ in {1..100}; do
    grep -Fq -- $'nohup\t' "$log" && break
    /usr/bin/sleep 0.01
  done
  grep -Fq -- $'nohup\tLINEAGE_DIR=\\<unset\\>' "$log" || \
    fail "qemu up did not use the default multilib rig directory"

  rm -f "$home/Android/lineage-multilib/vda.raw"
  mkdir -p "$tmp/override rig"
  : >"$tmp/override rig/vda.raw"
  : >"$log"
  LINEAGE_DIR="$tmp/override rig" FAKE_PGREP_RESULT=miss \
    FAKE_LAB_COMMAND_LOG="$log" run_lab "$home" "$bin" qemu up >/dev/null
  for _ in {1..100}; do
    grep -Fq -- $'nohup\t' "$log" && break
    /usr/bin/sleep 0.01
  done
  grep -Fq -- "LINEAGE_DIR=$(printf '%q' "$tmp/override rig")" "$log" || \
    fail "qemu up did not honor LINEAGE_DIR override"
  : >"$home/Android/lineage-multilib/vda.raw"

  : >"$log"
  FAKE_LAB_COMMAND_LOG="$log" DECLAW="$bin/declaw" \
    run_lab "$home" "$bin" qemu keylog com.example.app >/dev/null
  grep -Fq $'declaw\tcom.example.app\t--mode\tcapture\t-s\tlocalhost:6555' "$log" || \
    fail "qemu keylog was not recognized and dispatched"

  : >"$log"
  output=$(FAKE_PGREP_RESULT=miss FAKE_LAB_COMMAND_LOG="$log" \
    run_lab "$home" "$bin" qemu status)
  assert_line "$output" "[qemu] host-process=not-found"
  assert_line "$output" "[qemu] guest=reachable serial=localhost:6555"
  assert_line "$output" "[qemu] zygote=zygote64_32"
  assert_line "$output" "[qemu] abilist64=arm64-v8a"
  assert_line "$output" "[qemu] abilist32=armeabi-v7a,armeabi"
  grep -Fq '\[q\]emu-system-aarch64' "$log" || \
    fail "qemu status process match was not self-safe"

  set +e
  output=$(FAKE_ADB_PROFILE=unreachable FAKE_PGREP_RESULT=hit \
    run_lab "$home" "$bin" qemu status 2>&1)
  status=$?
  set -e
  [[ $status -eq 1 ]] || fail "qemu status unreachable guest returned $status, expected 1"
  assert_line "$output" "[qemu] host-process=running"
  assert_line "$output" "[qemu] guest=unreachable serial=localhost:6555"

  set +e
  output=$(FAKE_ADB_PROFILE=status-hang LAB_ADB_TIMEOUT=0.1 \
    run_lab "$home" "$bin" qemu status 2>&1)
  status=$?
  set -e
  [[ $status -eq 1 ]] || fail "qemu status hung adb returned $status, expected 1"
  assert_line "$output" "[qemu] guest=unreachable serial=localhost:6555"

  mkdir "$tmp/splits" "$tmp/bundle-source"
  make_apk "$tmp/splits/base.apk" lib/arm64-v8a/libdemo.so
  make_apk "$tmp/bundle-source/base.apk" lib/arm64-v8a/libdemo.so
  make_bundle "$tmp/demo.apkm" "$tmp/bundle-source"
  make_bundle "$tmp/demo.xapk" "$tmp/bundle-source"
  for path in "$tmp/demo app.apk" "$tmp/demo.apkm" "$tmp/demo.xapk" "$tmp/splits"; do
    set +e
    output=$(FAKE_ADB_FAIL_INSTALL=1 run_lab "$home" "$bin" qemu capture "$path" 2>&1)
    status=$?
    set -e
    [[ $status -eq 42 ]] || fail "capture installer failure for $path returned $status"
    grep -Fq '[install] ERROR: adb install failed with status 42' <<<"$output" || \
      fail "capture did not route $path through install-app.sh"
  done

  mkdir "$tmp/avd-bundle-source"
  make_apk "$tmp/avd-bundle-source/base.apk"
  make_apk "$tmp/avd-bundle-source/split_config.arm64_v8a.apk" \
    lib/arm64-v8a/libdemo.so
  make_apk "$tmp/avd-bundle-source/split_config.x86_64.apk" \
    lib/x86_64/libdemo.so
  make_bundle "$tmp/avd-mixed.apkm" "$tmp/avd-bundle-source"
  : >"$argv_log"
  : >"$install_log"
  set +e
  output=$(FAKE_ADB_PROFILE=avd FAKE_ADB_FAIL_INSTALL=1 \
    FAKE_ADB_ARGV_LOG="$argv_log" FAKE_ADB_INSTALL_LOG="$install_log" \
    run_lab "$home" "$bin" avd capture "$tmp/avd-mixed.apkm" 2>&1)
  status=$?
  set -e
  [[ $status -eq 42 ]] || fail "AVD capture installer failure returned $status"
  grep -Fq -- "install-multiple -r --abi x86_64" "$argv_log" || \
    fail "AVD capture did not select its x86_64 ABI"
  assert_line "$(<"$install_log")" \
    $'install-multiple\tbase.apk\tsplit_config.x86_64.apk'

  output=$(run_lab "$home" "$bin" --help)
  grep -Fq 'check' <<<"$output" || fail "lab help omitted check"
  grep -Fq 'install' <<<"$output" || fail "lab help omitted install"
  grep -Fq 'APKM' <<<"$output" || fail "lab help omitted APKM support"
  grep -Fq 'accept' <<<"$output" || fail "lab help omitted dual-ABI acceptance"

  echo "PASS: dispatch"
}

make_build_fakes() {
  local bin=$1
  mkdir -p "$bin"
  for command in git curl repo; do
    cat >"$bin/$command" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >>"$FAKE_BUILD_NETWORK_LOG"
echo "fake ${0##*/}: network/source access forbidden" >&2
exit 97
SH
    chmod +x "$bin/$command"
  done
}

run_build_preflight() {
  local bin=$1 disk_gib=$2 ram_gib=$3
  shift 3
  PATH="$bin:/usr/bin:/bin" BUILD_TEST_MODE=1 \
    BUILD_TEST_REQUIRED_TOOLS=bash BUILD_TEST_DISK_GIB="$disk_gib" \
    BUILD_TEST_RAM_GIB="$ram_gib" BUILD_TEST_QEMU_IMG_PATH=/usr/bin/true \
    BUILD_TEST_IMAGEMAGICK_TOOLS=true BUILD_TEST_SKIP_PYTHON_MODULES=1 \
    BUILD_PREFLIGHT_ONLY=1 \
    "$ROOT/avd/build-lineage-multilib.sh" "$@"
}

test_build() {
  local tmp bin log output status root dist product utm_dir valid_utm valid_ota
  local tools modules preflight_bin git_home git_root gitconfig home_hash
  local cleanup_product cleanup_utm unsafe_product source_dir tools_dir host_bin build_log
  local build_tmp override_tmp invalid_job invalid_tmp preflight_tmp
  tmp=$(mktemp -d)
  bin="$tmp/bin"
  log="$tmp/network.log"
  root="$tmp/build root"
  dist="$tmp/dist output"
  build_tmp="$root/tmp"
  trap 'rm -rf "$tmp"' RETURN
  : >"$log"
  make_build_fakes "$bin"

  set +e
  output=$(PATH="$bin:/usr/bin:/bin" FAKE_BUILD_NETWORK_LOG="$log" \
    BUILD_TEST_MODE=1 BUILD_TEST_NPROC=16 \
    BUILD_DRY_RUN=1 BUILD_ROOT="$root" BUILD_DIST_DIR="$dist" \
    BUILD_TIMESTAMP=20260713T120000Z \
    "$ROOT/avd/build-lineage-multilib.sh" 2>&1)
  status=$?
  set -e
  [[ $status -eq 0 ]] || {
    printf '%s\n' "$output" >&2
    fail "builder dry run returned $status"
  }
  assert_line "$output" \
    "[build] branch=lineage-23.2 target=virtio_arm64 variant=user"
  assert_line "$output" \
    "[build] abis=arm64-v8a,armeabi-v7a,armeabi zygote=zygote64_32"
  assert_line "$output" \
    "[build] builder=https://github.com/jqssun/android-lineage-qemu.git ref=v2026.07.09 commit=54fc5dc82fa05778be15c1200240be53f707a542"
  assert_line "$output" \
    "[build] manifest=https://github.com/LineageOS/android.git branch=lineage-23.2"
  assert_line "$output" \
    "[build] repo=https://storage.googleapis.com/git-repo-downloads/repo-2.54 sha256=6cba294d6218bbd4a1500598207b3979c752c7a122aef9429e4d7fef688833b5"
  assert_line "$output" "[build] root=$root"
  assert_line "$output" "[build] dist=$dist"
  assert_line "$output" "[build] jobs=4 tmp=$build_tmp"
  assert_line "$output" 'export PATH='"$root/tools"':$PATH'
  assert_line "$output" "export GIT_CONFIG_GLOBAL=$root/gitconfig"
  assert_line "$output" "export TMPDIR=$build_tmp"
  assert_line "$output" "git lfs install --skip-repo"
  assert_line "$output" 'git config --global user.name "Declaw Multilib Builder"'
  assert_line "$output" 'git config --global user.email "declaw-builder@localhost"'
  assert_line "$output" 'git config --global trailer.changeid.key "Change-Id"'
  assert_line "$output" \
    "repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --depth=1 --no-clone-bundle --git-lfs"
  assert_line "$output" "export AB_OTA_UPDATER=false"
  assert_line "$output" \
    'export ROOMSERVICE_BRANCHES="lineage-23.1 lineage-23.0"'
  assert_line "$output" "source $root/source/build/envsetup.sh"
  assert_line "$output" "breakfast virtio_arm64 user"
  assert_line "$output" "m -j4 vm-utm-zip otapackage"
  if grep -Eqi 'arm64only|(^|[^[:alnum:]_])x86([^[:alnum:]_]|$)|kvm|native.?bridge' <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "builder dry run emitted a forbidden target, accelerator, or translation layer"
  fi
  [[ ! -s $log ]] || fail "builder dry run invoked a network/source command"
  [[ ! -e $build_tmp ]] || fail "builder dry run created BUILD_TMP_DIR"

  override_tmp="$tmp/dedicated temp"
  output=$(PATH="$bin:/usr/bin:/bin" FAKE_BUILD_NETWORK_LOG="$log" \
    BUILD_DRY_RUN=1 BUILD_ROOT="$root" BUILD_DIST_DIR="$dist" \
    BUILD_JOBS=2 BUILD_TMP_DIR="$override_tmp" \
    "$ROOT/avd/build-lineage-multilib.sh")
  assert_line "$output" "[build] jobs=2 tmp=$override_tmp"
  assert_line "$output" "export TMPDIR=$override_tmp"
  assert_line "$output" "m -j2 vm-utm-zip otapackage"
  [[ ! -e $override_tmp ]] || fail "builder dry run created overridden BUILD_TMP_DIR"

  for invalid_job in 0 -1 nope 1.5; do
    set +e
    output=$(PATH="$bin:/usr/bin:/bin" FAKE_BUILD_NETWORK_LOG="$log" \
      BUILD_DRY_RUN=1 BUILD_ROOT="$root" BUILD_JOBS="$invalid_job" \
      "$ROOT/avd/build-lineage-multilib.sh" 2>&1)
    status=$?
    set -e
    [[ $status -eq 2 ]] || \
      fail "BUILD_JOBS=$invalid_job returned $status, expected 2"
    grep -Fq -- "BUILD_JOBS must be a positive integer" <<<"$output" || \
      fail "invalid BUILD_JOBS=$invalid_job omitted the validation error"
  done

  for invalid_tmp in / // relative/tmp; do
    set +e
    output=$(PATH="$bin:/usr/bin:/bin" FAKE_BUILD_NETWORK_LOG="$log" \
      BUILD_DRY_RUN=1 BUILD_ROOT="$root" BUILD_TMP_DIR="$invalid_tmp" \
      "$ROOT/avd/build-lineage-multilib.sh" 2>&1)
    status=$?
    set -e
    [[ $status -eq 2 ]] || \
      fail "BUILD_TMP_DIR=$invalid_tmp returned $status, expected 2"
    grep -Fq -- "BUILD_TMP_DIR must be an absolute non-root path" <<<"$output" || \
      fail "unsafe BUILD_TMP_DIR=$invalid_tmp omitted the validation error"
  done
  [[ ! -s $log ]] || fail "resource-setting validation reached git/curl/repo"

  tools=$(bash -c 'source "$1"; required_tools' \
    build-tools-test "$ROOT/avd/build-lineage-multilib.sh")
  for tool in ccache lz4 lzop protoc meson glslangValidator schedtool mksquashfs; do
    assert_line "$tools" "$tool"
  done
  output=$(bash -c 'source "$1"; printf "%s" "$QEMU_IMG_PATH"' \
    build-tools-test "$ROOT/avd/build-lineage-multilib.sh")
  [[ $output == /usr/bin/qemu-img ]] || \
    fail "builder did not require the UTM makefile's exact /usr/bin/qemu-img"
  modules=$(bash -c 'source "$1"; required_python_modules' \
    build-tools-test "$ROOT/avd/build-lineage-multilib.sh")
  assert_line "$modules" yaml
  assert_line "$modules" google.protobuf
  assert_line "$modules" mako

  preflight_bin="$tmp/preflight-bin"
  mkdir -p "$preflight_bin"
  make_build_fakes "$preflight_bin"
  cat >"$preflight_bin/python3" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$preflight_bin/python3"
  : >"$log"
  set +e
  output=$(PATH="$preflight_bin:/usr/bin:/bin" FAKE_BUILD_NETWORK_LOG="$log" \
    BUILD_TEST_MODE=1 BUILD_TEST_REQUIRED_TOOLS='missing-tool-one missing-tool-two' \
    BUILD_TEST_QEMU_IMG_PATH="$tmp/missing-qemu-img" \
    BUILD_TEST_IMAGEMAGICK_TOOLS='missing-magick missing-convert' \
    BUILD_TEST_DISK_GIB=999 BUILD_TEST_RAM_GIB=999 BUILD_PREFLIGHT_ONLY=1 \
    BUILD_ROOT="$root" "$ROOT/avd/build-lineage-multilib.sh" 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "aggregated dependency preflight returned $status, expected 2"
  assert_line "$output" "[build] ERROR: missing required host tool: missing-tool-one"
  assert_line "$output" "[build] ERROR: missing required host tool: missing-tool-two"
  assert_line "$output" \
    "[build] ERROR: missing required executable: $tmp/missing-qemu-img"
  assert_line "$output" \
    "[build] ERROR: missing ImageMagick command (need magick or convert)"
  assert_line "$output" "[build] ERROR: missing required Python module: yaml"
  assert_line "$output" "[build] ERROR: missing required Python module: google.protobuf"
  assert_line "$output" "[build] ERROR: missing required Python module: mako"
  [[ ! -s $log ]] || fail "dependency preflight reached git/curl/repo"

  git_home="$tmp/git-home"
  git_root="$tmp/git build root"
  gitconfig="$git_root/gitconfig"
  mkdir -p "$git_home"
  printf '[user]\n\tname = Pentester\n' >"$git_home/.gitconfig"
  home_hash=$(sha256sum "$git_home/.gitconfig" | awk '{ print $1 }')
  HOME="$git_home" BUILD_ROOT="$git_root" bash -c \
    'source "$1"; mkdir -p "$BUILD_ROOT"; configure_git_identity' \
    build-git-test "$ROOT/avd/build-lineage-multilib.sh"
  [[ $(sha256sum "$git_home/.gitconfig" | awk '{ print $1 }') == "$home_hash" ]] || \
    fail "builder mutated the operator's normal ~/.gitconfig"
  [[ ! -e $git_home/.config/git/config ]] || \
    fail "builder created the operator's XDG git config"
  [[ $(git config --file "$gitconfig" --get user.name) == 'Declaw Multilib Builder' ]] || \
    fail "isolated builder gitconfig omitted user.name"
  [[ $(git config --file "$gitconfig" --get user.email) == 'declaw-builder@localhost' ]] || \
    fail "isolated builder gitconfig omitted user.email"
  [[ $(git config --file "$gitconfig" --get trailer.changeid.key) == Change-Id ]] || \
    fail "isolated builder gitconfig omitted the Change-Id trailer key"

  product="$tmp/product/out/target/product/virtio_arm64"
  utm_dir="$product/VirtualMachine/UTM"
  mkdir -p "$utm_dir"
  set +e
  output=$(bash -c 'source "$1"; find_utm_artifact "$2"' \
    build-artifact-test "$ROOT/avd/build-lineage-multilib.sh" "$product" 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "missing nested UTM artifact returned $status, expected 2"
  grep -Fq -- "found 0" <<<"$output" || \
    fail "missing nested UTM error omitted the match count"

  : >"$utm_dir/UTM-VM-lineage-test-virtio_arm64only.zip"
  : >"$product/UTM-VM-lineage-test-virtio_arm64.zip"
  set +e
  output=$(bash -c 'source "$1"; find_utm_artifact "$2"' \
    build-artifact-test "$ROOT/avd/build-lineage-multilib.sh" "$product" 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "wrong-product UTM artifact returned $status, expected 2"
  grep -Fq -- "found 0" <<<"$output" || \
    fail "UTM discovery accepted the wrong product or product-root layout"

  valid_utm="$utm_dir/UTM-VM-lineage-test-virtio_arm64.zip"
  : >"$valid_utm"
  output=$(bash -c 'source "$1"; find_utm_artifact "$2"' \
    build-artifact-test "$ROOT/avd/build-lineage-multilib.sh" "$product")
  [[ $output == "$valid_utm" ]] || fail "UTM discovery did not return the sole exact artifact"
  : >"$utm_dir/UTM-VM-lineage-other-virtio_arm64.zip"
  set +e
  output=$(bash -c 'source "$1"; find_utm_artifact "$2"' \
    build-artifact-test "$ROOT/avd/build-lineage-multilib.sh" "$product" 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "ambiguous nested UTM artifacts returned $status, expected 2"
  grep -Fq -- "found 2" <<<"$output" || \
    fail "ambiguous nested UTM error omitted the match count"

  : >"$product/lineage-23.2-test-virtio_arm64.zip"
  set +e
  output=$(bash -c 'source "$1"; find_ota_artifact "$2"' \
    build-artifact-test "$ROOT/avd/build-lineage-multilib.sh" "$product" 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "non-exact OTA artifact returned $status, expected 2"
  grep -Fq -- "found 0" <<<"$output" || \
    fail "OTA discovery accepted a non-product output name"

  valid_ota="$product/lineage_virtio_arm64-ota.zip"
  : >"$valid_ota"
  output=$(bash -c 'source "$1"; find_ota_artifact "$2"' \
    build-artifact-test "$ROOT/avd/build-lineage-multilib.sh" "$product")
  [[ $output == "$valid_ota" ]] || fail "OTA discovery did not return the sole exact artifact"

  cleanup_product="$tmp/cleanup/out/target/product/virtio_arm64"
  cleanup_utm="$cleanup_product/VirtualMachine/UTM"
  mkdir -p "$cleanup_utm"
  : >"$cleanup_product/lineage_virtio_arm64-ota.zip"
  : >"$cleanup_product/lineage_other-product-ota.zip"
  : >"$cleanup_product/UTM-VM-root-virtio_arm64.zip"
  : >"$cleanup_utm/UTM-VM-old-virtio_arm64.zip"
  : >"$cleanup_utm/UTM-VM-newer-virtio_arm64.zip"
  : >"$cleanup_utm/UTM-VM-old-virtio_arm64only.zip"
  : >"$cleanup_utm/operator-notes.zip"
  bash -c 'source "$1"; clean_target_artifacts "$2"' \
    build-clean-test "$ROOT/avd/build-lineage-multilib.sh" "$cleanup_product"
  [[ ! -e $cleanup_product/lineage_virtio_arm64-ota.zip ]] || \
    fail "target cleanup left the exact stale OTA"
  [[ ! -e $cleanup_utm/UTM-VM-old-virtio_arm64.zip && \
     ! -e $cleanup_utm/UTM-VM-newer-virtio_arm64.zip ]] || \
    fail "target cleanup left exact stale UTM artifacts"
  for preserved in \
    "$cleanup_product/lineage_other-product-ota.zip" \
    "$cleanup_product/UTM-VM-root-virtio_arm64.zip" \
    "$cleanup_utm/UTM-VM-old-virtio_arm64only.zip" \
    "$cleanup_utm/operator-notes.zip"; do
    [[ -e $preserved ]] || fail "target cleanup removed unrelated file: $preserved"
  done
  unsafe_product="$tmp/cleanup/out/target/product/not-the-current-target"
  mkdir -p "$unsafe_product"
  : >"$unsafe_product/lineage_virtio_arm64-ota.zip"
  assert_status 2 bash -c 'source "$1"; clean_target_artifacts "$2"' \
    build-clean-test "$ROOT/avd/build-lineage-multilib.sh" "$unsafe_product"
  [[ -e $unsafe_product/lineage_virtio_arm64-ota.zip ]] || \
    fail "target cleanup removed a file outside the current product directory"

  source_dir="$tmp/build-target/source"
  tools_dir="$tmp/build-target/pinned-tools"
  host_bin="$tmp/build-target/host-bin"
  build_log="$tmp/build-target.log"
  mkdir -p "$source_dir/build" "$tools_dir" "$host_bin"
  : >"$build_log"
  cat >"$tools_dir/repo" <<'SH'
#!/usr/bin/env bash
printf 'pinned-repo\t%s\n' "$*" >>"$FAKE_BUILD_TARGET_LOG"
exit 0
SH
  cat >"$host_bin/repo" <<'SH'
#!/usr/bin/env bash
printf 'HOST-REPO\t%s\n' "$*" >>"$FAKE_BUILD_TARGET_LOG"
exit 97
SH
  chmod +x "$tools_dir/repo" "$host_bin/repo"
  cat >"$source_dir/build/envsetup.sh" <<'SH'
breakfast() {
  printf 'breakfast\t%s\trepo=%s\ttmp=%s\n' \
    "$*" "$(command -v repo)" "$TMPDIR" >>"$FAKE_BUILD_TARGET_LOG"
  mkdir -p "$FAKE_BUILD_PRODUCT/VirtualMachine/UTM"
  : >"$FAKE_BUILD_PRODUCT/lineage_virtio_arm64-ota.zip"
  : >"$FAKE_BUILD_PRODUCT/VirtualMachine/UTM/UTM-VM-stale-virtio_arm64.zip"
  : >"$FAKE_BUILD_PRODUCT/VirtualMachine/UTM/UTM-VM-keep-virtio_arm64only.zip"
  repo from-breakfast
}
m() {
  [[ ! -e $FAKE_BUILD_PRODUCT/lineage_virtio_arm64-ota.zip ]] || return 91
  [[ ! -e $FAKE_BUILD_PRODUCT/VirtualMachine/UTM/UTM-VM-stale-virtio_arm64.zip ]] || return 92
  [[ -e $FAKE_BUILD_PRODUCT/VirtualMachine/UTM/UTM-VM-keep-virtio_arm64only.zip ]] || return 93
  printf 'm\t%s\trepo=%s\ttmp=%s\n' \
    "$*" "$(command -v repo)" "$TMPDIR" >>"$FAKE_BUILD_TARGET_LOG"
  repo from-build
}
SH
  PATH="$host_bin:/usr/bin:/bin" BUILD_ROOT="$tmp/build-target" \
    BUILD_JOBS=3 BUILD_TMP_DIR="$tmp/build-target/tmp" \
    LINEAGE_SOURCE_DIR="$source_dir" BUILD_TOOLS_DIR="$tools_dir" \
    FAKE_BUILD_PRODUCT="$source_dir/out/target/product/virtio_arm64" \
    FAKE_BUILD_TARGET_LOG="$build_log" bash -c \
    'source "$1"; validate_build_settings; activate_build_tmp; build_target' build-target-test \
    "$ROOT/avd/build-lineage-multilib.sh"
  grep -Fq -- $'breakfast\tvirtio_arm64 user\trepo='"$tools_dir/repo"$'\ttmp='"$tmp/build-target/tmp" "$build_log" || \
    fail "breakfast did not resolve repo from the pinned tools directory"
  grep -Fq -- $'m\t-j3 vm-utm-zip otapackage\trepo='"$tools_dir/repo"$'\ttmp='"$tmp/build-target/tmp" "$build_log" || \
    fail "build did not use bounded jobs, pinned repo, and BUILD_TMP_DIR"
  [[ -d $tmp/build-target/tmp ]] || fail "active build did not create BUILD_TMP_DIR"
  assert_line "$(grep '^pinned-repo' "$build_log")" $'pinned-repo\tfrom-breakfast'
  assert_line "$(grep '^pinned-repo' "$build_log")" $'pinned-repo\tfrom-build'
  if grep -Fq HOST-REPO "$build_log"; then
    fail "build/Roomservice invoked a host repo instead of the pinned launcher"
  fi

  : >"$log"
  preflight_tmp="$tmp/preflight-only-tmp"
  output=$(FAKE_BUILD_NETWORK_LOG="$log" BUILD_TMP_DIR="$preflight_tmp" \
    run_build_preflight "$bin" 400 64 2>&1)
  grep -Fq -- "[build] preflight-only: PASS" <<<"$output" || \
    fail "preflight-only resource test did not pass"
  [[ ! -e $preflight_tmp ]] || fail "preflight-only mode created BUILD_TMP_DIR"
  [[ ! -s $log ]] || fail "preflight-only resource test reached git/curl/repo"

  : >"$log"
  set +e
  output=$(PATH="$bin:/usr/bin:/bin" FAKE_BUILD_NETWORK_LOG="$log" \
    BUILD_TEST_MODE=1 BUILD_TEST_REQUIRED_TOOLS=missing-lineage-tool \
    BUILD_TEST_QEMU_IMG_PATH=/usr/bin/true BUILD_TEST_IMAGEMAGICK_TOOLS=true \
    BUILD_TEST_SKIP_PYTHON_MODULES=1 \
    BUILD_TEST_DISK_GIB=999 BUILD_TEST_RAM_GIB=999 BUILD_PREFLIGHT_ONLY=1 \
    BUILD_ROOT="$root" "$ROOT/avd/build-lineage-multilib.sh" 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "missing build tool returned $status, expected 2"
  grep -Fq -- "missing required host tool: missing-lineage-tool" <<<"$output" || \
    fail "missing-tool preflight omitted the tool name"
  [[ ! -s $log ]] || fail "missing-tool preflight reached git/curl/repo"

  : >"$log"
  set +e
  output=$(FAKE_BUILD_NETWORK_LOG="$log" run_build_preflight "$bin" 399 64 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "undersized disk returned $status, expected 2"
  grep -Fq -- "need at least 400 GiB free" <<<"$output" || \
    fail "disk preflight omitted the 400 GiB requirement"
  [[ ! -s $log ]] || fail "disk preflight reached git/curl/repo"

  : >"$log"
  set +e
  output=$(FAKE_BUILD_NETWORK_LOG="$log" run_build_preflight "$bin" 400 63 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "undersized RAM returned $status, expected 2"
  grep -Fq -- "need at least 64 GiB RAM" <<<"$output" || \
    fail "RAM preflight omitted the 64 GiB requirement"
  [[ ! -s $log ]] || fail "RAM preflight reached git/curl/repo"

  : >"$log"
  output=$(FAKE_BUILD_NETWORK_LOG="$log" ALLOW_UNDERSIZED_BUILD=1 \
    run_build_preflight "$bin" 1 1 2>&1)
  grep -Fq -- "WARNING: continuing with 1 GiB free and 1 GiB RAM" <<<"$output" || \
    fail "undersized override omitted a prominent warning"
  grep -Fq -- "[build] preflight-only: PASS" <<<"$output" || \
    fail "preflight-only success was not explicit"
  [[ ! -s $log ]] || fail "preflight-only mode reached git/curl/repo"

  echo "PASS: build"
}

make_provision_fakes() {
  local bin=$1 mode=${2:-forbid}
  mkdir -p "$bin"
  cat >"$bin/qemu-img" <<'SH'
#!/usr/bin/env bash
printf 'qemu-img\t%s\n' "$*" >>"$FAKE_PROVISION_COMMAND_LOG"
case "${FAKE_QEMU_IMG_MODE:-forbid}" in
  forbid) exit 97 ;;
  fail) exit 42 ;;
  copy)
    [[ ${1:-} == convert ]] || exit 96
    cp -- "${@: -2:1}" "${@: -1}"
    ;;
  pristine|already-patched|conflicting)
    /usr/bin/python3 - "${@: -1}" "$FAKE_QEMU_IMG_MODE" <<'PY'
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
image = bytearray(64 * 512)
partition = 4 * 512
image[partition:partition + 8] = b"VNDRBOOT"
if mode == "pristine":
    cmdline = b"console=ttyAMA0 androidboot.hardware=virt"
elif mode == "already-patched":
    cmdline = b"console=ttyAMA0 androidboot.debuggable=1 androidboot.selinux=permissive"
else:
    cmdline = b"console=ttyAMA0 androidboot.debuggable=0 androidboot.selinux=enforcing"
image[partition + 28:partition + 28 + len(cmdline)] = cmdline
properties = b"ro.debuggable=0\x00ro.adb.secure=1\x00"
image[20 * 512:20 * 512 + len(properties)] = properties
output.write_bytes(image)
PY
    ;;
  *) exit 95 ;;
esac
SH
  cat >"$bin/unzip" <<'SH'
#!/usr/bin/env bash
printf 'unzip\t%s\n' "$*" >>"$FAKE_PROVISION_COMMAND_LOG"
exit 97
SH
  cat >"$bin/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl\t%s\n' "$*" >>"$FAKE_PROVISION_COMMAND_LOG"
exit 97
SH
  cat >"$bin/taskset" <<'SH'
#!/usr/bin/env bash
printf 'taskset\t%s\n' "$*" >>"$FAKE_PROVISION_COMMAND_LOG"
exit 97
SH
  cat >"$bin/qemu-system-aarch64" <<'SH'
#!/usr/bin/env bash
printf 'qemu-system-aarch64\t%s\n' "$*" >>"$FAKE_PROVISION_COMMAND_LOG"
exit 97
SH
  chmod +x "$bin"/*
}

assert_no_staging_dir() {
  local target=$1 found
  found=$(compgen -G "${target}.staging.*" || true)
  [[ -z $found ]] || fail "provisioning left staging directories: $found"
}

test_provision() {
  local tmp home bin log archive before output status target build_root newest old
  local bad wrong malformed missing unsafe duplicate top_payload collision fifo
  local sentinel boot_home override mode case_dir case_archive
  local before_metadata before_sums newest_sha metadata_sha sums_sha raw_sha
  tmp=$(mktemp -d)
  home="$tmp/home"
  bin="$tmp/bin"
  log="$tmp/commands.log"
  target="$home/Android/lineage-multilib"
  archive="$tmp/UTM-VM-lineage-test-virtio_arm64.zip"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$home"
  : >"$log"
  make_provision_fakes "$bin"
  make_utm_archive "$archive"
  make_builder_sidecars "$archive"
  before=$(sha256sum "$archive" | awk '{ print $1 }')
  before_metadata=$(sha256sum "$(dirname "$archive")/build-metadata.txt" | awk '{ print $1 }')
  before_sums=$(sha256sum "$(dirname "$archive")/SHA256SUMS" | awk '{ print $1 }')

  output=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
    FAKE_PROVISION_COMMAND_LOG="$log" LINEAGE_MULTILIB_ZIP="$archive" \
    PROVISION_DRY_RUN=1 "$ROOT/avd/provision.sh")
  assert_line "$output" "[provision] source=$archive"
  assert_line "$output" "[provision] sha256=$before"
  assert_line "$output" \
    "[provision] contract=android=16 sdk=36 abis=arm64-v8a,armeabi-v7a,armeabi zygote=zygote64_32"
  assert_line "$output" "[provision] target=$target"
  grep -Fq -- "stage" <<<"$output" || fail "dry run omitted the staging action"
  grep -Fq -- "vda.qcow2" <<<"$output" || fail "dry run omitted the conversion source"
  grep -Fq -- "vda.raw" <<<"$output" || fail "dry run omitted the converted disk"
  [[ ! -e $target ]] || fail "provision dry run created its target"
  [[ $(sha256sum "$archive" | awk '{ print $1 }') == "$before" ]] || \
    fail "provisioning modified the explicit source archive"
  [[ $(sha256sum "$(dirname "$archive")/build-metadata.txt" | awk '{ print $1 }') == "$before_metadata" ]] || \
    fail "provisioning modified build-metadata.txt"
  [[ $(sha256sum "$(dirname "$archive")/SHA256SUMS" | awk '{ print $1 }') == "$before_sums" ]] || \
    fail "provisioning modified SHA256SUMS"
  [[ ! -s $log ]] || fail "provision dry run invoked unzip, qemu, taskset, or network"

  wrong="$tmp/invalid/wrong-name/lineage-virtio_arm64.zip"
  mkdir -p "$(dirname "$wrong")"
  cp "$archive" "$wrong"
  bad="$tmp/invalid/arm64only/UTM-VM-lineage-test-virtio_arm64only.zip"
  mkdir -p "$(dirname "$bad")"
  cp "$archive" "$bad"
  malformed="$tmp/invalid/malformed/UTM-VM-malformed-virtio_arm64.zip"
  mkdir -p "$(dirname "$malformed")"
  printf 'not a zip\n' >"$malformed"
  missing="$tmp/invalid/missing/UTM-VM-missing-virtio_arm64.zip"
  unsafe="$tmp/invalid/unsafe/UTM-VM-unsafe-virtio_arm64.zip"
  duplicate="$tmp/invalid/duplicate/UTM-VM-duplicate-virtio_arm64.zip"
  top_payload="$tmp/invalid/top-level/UTM-VM-top-level-virtio_arm64.zip"
  collision="$tmp/invalid/collision/UTM-VM-collision-virtio_arm64.zip"
  fifo="$tmp/invalid/fifo/UTM-VM-fifo-virtio_arm64.zip"
  make_utm_archive "$missing" missing-layout
  make_utm_archive "$unsafe" unsafe
  make_utm_archive "$duplicate" duplicate-utm
  make_utm_archive "$top_payload" top-level-payload
  make_utm_archive "$collision" normalized-collision
  make_utm_archive "$fifo" special-fifo
  for archive in "$bad" "$wrong" "$malformed" "$missing" "$unsafe" "$duplicate" \
    "$top_payload" "$collision" "$fifo"; do
    make_builder_sidecars "$archive"
    : >"$log"
    set +e
    output=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
      FAKE_PROVISION_COMMAND_LOG="$log" LINEAGE_MULTILIB_ZIP="$archive" \
      PROVISION_DRY_RUN=1 "$ROOT/avd/provision.sh" 2>&1)
    status=$?
    set -e
    [[ $status -eq 2 ]] || {
      printf '%s\n' "$output" >&2
      fail "invalid archive $(basename "$archive") returned $status, expected 2"
    }
    [[ ! -s $log ]] || fail "invalid dry-run archive invoked external mutation commands"
    [[ ! -e $target ]] || fail "invalid archive published a rig"
  done

  for mode in missing-metadata missing-sums wrong-archive-hash \
    wrong-metadata-hash duplicate-archive-entry metadata-arm64only metadata-wrong-abi \
    renamed-artifact; do
    case_dir="$tmp/sidecar-cases/$mode"
    case_archive="$case_dir/UTM-VM-$mode-virtio_arm64.zip"
    make_utm_archive "$case_archive"
    make_builder_sidecars "$case_archive" "$mode"
    case "$mode" in
      missing-metadata) rm -f "$case_dir/build-metadata.txt" ;;
      missing-sums) rm -f "$case_dir/SHA256SUMS" ;;
      renamed-artifact)
        mv "$case_archive" "$case_dir/UTM-VM-renamed-virtio_arm64.zip"
        case_archive="$case_dir/UTM-VM-renamed-virtio_arm64.zip"
        ;;
    esac
    : >"$log"
    set +e
    output=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
      FAKE_PROVISION_COMMAND_LOG="$log" LINEAGE_MULTILIB_ZIP="$case_archive" \
      PROVISION_DRY_RUN=1 "$ROOT/avd/provision.sh" 2>&1)
    status=$?
    set -e
    [[ $status -eq 2 ]] || {
      printf '%s\n' "$output" >&2
      fail "invalid builder sidecars $mode returned $status, expected 2"
    }
    [[ ! -s $log ]] || fail "invalid sidecars invoked external mutation commands"
    [[ ! -e $target ]] || fail "invalid sidecars published a rig"
  done

  build_root="$tmp/build"
  old="$build_root/dist/20260712-old-virtio_arm64/UTM-VM-old-virtio_arm64.zip"
  newest="$build_root/dist/20260713-new-virtio_arm64/UTM-VM-new-virtio_arm64.zip"
  make_utm_archive "$old"
  make_utm_archive "$newest"
  make_builder_sidecars "$old"
  make_builder_sidecars "$newest"
  touch -t 202607121200 "$old"
  touch -t 202607131200 "$newest"
  output=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
    FAKE_PROVISION_COMMAND_LOG="$log" BUILD_ROOT="$build_root" \
    PROVISION_DRY_RUN=1 "$ROOT/avd/provision.sh")
  assert_line "$output" "[provision] source=$newest"

  mkdir -p "$target"
  sentinel="$target/operator-data"
  printf 'keep me\n' >"$sentinel"
  set +e
  output=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
    FAKE_PROVISION_COMMAND_LOG="$log" LINEAGE_MULTILIB_ZIP="$newest" \
    "$ROOT/avd/provision.sh" 2>&1)
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "existing target returned $status, expected 2"
  [[ $(<"$sentinel") == 'keep me' ]] || fail "existing rig sentinel was overwritten"
  rm -rf "$target"

  cp /usr/bin/unzip "$bin/unzip"
  : >"$log"
  set +e
  output=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
    FAKE_QEMU_IMG_MODE=fail FAKE_PROVISION_COMMAND_LOG="$log" \
    LINEAGE_MULTILIB_ZIP="$newest" "$ROOT/avd/provision.sh" 2>&1)
  status=$?
  set -e
  [[ $status -eq 42 ]] || fail "injected conversion failure returned $status, expected 42"
  [[ ! -e $target ]] || fail "conversion failure published a partial rig"
  assert_no_staging_dir "$target"

  cat >"$bin/parted" <<'SH'
#!/usr/bin/env bash
printf 'parted\t%s\n' "$*" >>"$FAKE_PROVISION_COMMAND_LOG"
cat <<'EOF'
BYT;
fixture.raw:64s:file:512:512:gpt:fixture:;
1:4s:19s:16s::vendor_boot:;
EOF
SH
  chmod +x "$bin/parted"
  for mode in already-patched conflicting; do
    : >"$log"
    set +e
    output=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
      FAKE_QEMU_IMG_MODE="$mode" FAKE_PROVISION_COMMAND_LOG="$log" \
      LINEAGE_MULTILIB_ZIP="$newest" "$ROOT/avd/provision.sh" 2>&1)
    status=$?
    set -e
    [[ $status -eq 2 ]] || {
      printf '%s\n' "$output" >&2
      fail "$mode vendor_boot source returned $status, expected 2"
    }
    [[ ! -e $target ]] || fail "$mode vendor_boot source published a rig"
    assert_no_staging_dir "$target"
  done

  newest_sha=$(sha256sum "$newest" | awk '{print $1}')
  metadata_sha=$(sha256sum "$(dirname "$newest")/build-metadata.txt" | awk '{print $1}')
  sums_sha=$(sha256sum "$(dirname "$newest")/SHA256SUMS" | awk '{print $1}')
  : >"$log"
  output=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
    FAKE_QEMU_IMG_MODE=pristine FAKE_PROVISION_COMMAND_LOG="$log" \
    LINEAGE_MULTILIB_ZIP="$newest" "$ROOT/avd/provision.sh")
  assert_line "$output" "[provision] PASS: published complete multilib rig at $target"
  [[ -f $target/vda.raw ]] || fail "successful provisioning omitted vda.raw"
  python3 - "$target/vda.raw" <<'PY'
import pathlib
import sys

image = pathlib.Path(sys.argv[1]).read_bytes()
partition = 4 * 512
assert image[partition:partition + 8] == b"VNDRBOOT"
cmdline = image[partition + 28:partition + 28 + 2048].split(b"\0", 1)[0].decode().split()
assert cmdline.count("androidboot.debuggable=1") == 1, cmdline
assert cmdline.count("androidboot.selinux=permissive") == 1, cmdline
assert image.count(b"ro.debuggable=0") == 0
assert image.count(b"ro.adb.secure=1") == 0
assert image.count(b"ro.debuggable=1") == 1
assert image.count(b"ro.adb.secure=0") == 1
PY
  [[ $(<"$target/LineageOS_on_arm64.utm/config.plist") == plist ]] || \
    fail "published rig omitted the UTM config"
  [[ $(<"$target/LineageOS_on_arm64.utm/Data/efi_vars.fd") == efi-vars ]] || \
    fail "published rig omitted the UTM EFI vars"
  [[ $(<"$target/LineageOS_on_arm64.utm/Data/vdb.qcow2") == fake-data-qcow2 ]] || \
    fail "published rig omitted the UTM data disk"
  assert_line "$(<"$target/artifact.sha256")" "$newest_sha  $(basename "$newest")"
  raw_sha=$(sha256sum "$target/vda.raw" | awk '{print $1}')
  grep -Fqx -- "source_sha256=$newest_sha" "$target/provenance.txt" || \
    fail "provenance omitted the verified source hash"
  grep -Fqx -- "vda_raw_sha256=$raw_sha" "$target/provenance.txt" || \
    fail "provenance omitted the published raw hash"
  [[ $(sha256sum "$target/build-metadata.txt" | awk '{print $1}') == "$metadata_sha" ]] || \
    fail "published builder metadata differs from the verified sidecar"
  [[ $(sha256sum "$target/SHA256SUMS" | awk '{print $1}') == "$sums_sha" ]] || \
    fail "published checksum manifest differs from the verified sidecar"
  [[ ! -e $target/.input && ! -e $target/$(basename "$newest") ]] || \
    fail "published rig retained its large staged input copy"
  [[ $(sha256sum "$newest" | awk '{print $1}') == "$newest_sha" ]] || \
    fail "successful provisioning changed its source ZIP"
  [[ $(sha256sum "$(dirname "$newest")/build-metadata.txt" | awk '{print $1}') == "$metadata_sha" ]] || \
    fail "successful provisioning changed source metadata"
  [[ $(sha256sum "$(dirname "$newest")/SHA256SUMS" | awk '{print $1}') == "$sums_sha" ]] || \
    fail "successful provisioning changed source checksums"
  assert_no_staging_dir "$target"
  rm -rf "$target"

  # Let extraction and conversion succeed, then fail the first partition probe.
  # The published target must still be absent and staging must be cleaned.
  cat >"$bin/parted" <<'SH'
#!/usr/bin/env bash
printf 'parted\t%s\n' "$*" >>"$FAKE_PROVISION_COMMAND_LOG"
exit 43
SH
  chmod +x "$bin/parted"
  : >"$log"
  set +e
  output=$(HOME="$home" PATH="$bin:/usr/bin:/bin" \
    FAKE_QEMU_IMG_MODE=copy FAKE_PROVISION_COMMAND_LOG="$log" \
    LINEAGE_MULTILIB_ZIP="$newest" "$ROOT/avd/provision.sh" 2>&1)
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "injected patch failure unexpectedly succeeded"
  [[ ! -e $target ]] || fail "patch failure published a partial rig"
  assert_no_staging_dir "$target"

  boot_home="$tmp/boot-home"
  : >"$log"
  output=$(HOME="$boot_home" PATH="$bin:/usr/bin:/bin" \
    FAKE_PROVISION_COMMAND_LOG="$log" DRY_RUN=1 "$ROOT/avd/boot-arm64.sh")
  grep -Fq -- 'qemu-system-aarch64' <<<"$output" || fail "boot dry run omitted ARM QEMU"
  grep -Fq -- '-cpu max,pauth-impdef=on' <<<"$output" || fail "boot dry run omitted ARM CPU"
  grep -Fq -- '-accel tcg,thread=multi,tb-size=1024' <<<"$output" || \
    fail "boot dry run omitted tuned TCG"
  grep -Fq -- "$boot_home/Android/lineage-multilib/vda.raw" <<<"$output" || \
    fail "boot dry run did not use the multilib directory"
  if grep -Eqi 'qemu-system-x86|(^|[^[:alnum:]])kvm([^[:alnum:]]|$)|native.?bridge' <<<"$output"; then
    fail "boot dry run emitted a forbidden x86/KVM/native-bridge path"
  fi
  [[ ! -e $boot_home/Android ]] || fail "boot dry run wrote its run directory or firmware"
  [[ ! -s $log ]] || fail "boot dry run invoked qemu or taskset"

  override="$tmp/custom rig"
  output=$(HOME="$boot_home" LINEAGE_DIR="$override" PATH="$bin:/usr/bin:/bin" \
    FAKE_PROVISION_COMMAND_LOG="$log" DRY_RUN=1 "$ROOT/avd/boot-arm64.sh")
  grep -Fq -- "$override/vda.raw" <<<"$output" || \
    fail "boot dry run ignored LINEAGE_DIR override"

  echo "PASS: provision"
}

case ${1:-all} in
  checker) test_checker ;;
  installer) test_installer ;;
  acceptance) test_acceptance ;;
  dispatch) test_dispatch ;;
  build) test_build ;;
  provision) test_provision ;;
  all) test_checker; test_installer; test_acceptance; test_dispatch; test_build; test_provision ;;
  *) fail "unknown test group: ${1:-}" ;;
esac
