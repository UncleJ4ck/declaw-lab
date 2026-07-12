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

case ${1:-all} in
  checker) test_checker ;;
  all) test_checker ;;
  *) fail "unknown test group: ${1:-}" ;;
esac
