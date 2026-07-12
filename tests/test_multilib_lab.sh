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
  assert_status 2 "$ROOT/avd/install-app.sh" test-serial --abi x86 "$tmp/demo.apk"
  assert_status 2 "$ROOT/avd/install-app.sh" test-serial "$tmp/does-not-exist.apkm"

  set +e
  PATH="$FAKES:$PATH" FAKE_ADB_PROFILE=installer FAKE_ADB_FAIL_INSTALL=1 \
    "$ROOT/avd/install-app.sh" test-serial "$tmp/demo.apk" >/dev/null 2>&1
  status=$?
  set -e
  [[ $status -eq 42 ]] || fail "adb install failure returned $status, expected 42"

  echo "PASS: installer"
}

case ${1:-all} in
  checker) test_checker ;;
  installer) test_installer ;;
  all) test_checker; test_installer ;;
  *) fail "unknown test group: ${1:-}" ;;
esac
