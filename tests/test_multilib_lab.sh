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
  tmp=$(mktemp -d)
  home="$tmp/home"
  bin="$tmp/bin"
  log="$tmp/commands.log"
  argv_log="$tmp/argv.log"
  install_log="$tmp/install.log"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$home/Android/lineage-arm64" "$home/empty-sdk"
  : >"$home/Android/lineage-arm64/vda.raw"
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
  rm -f "$home/Android/lineage-arm64/vda.raw"
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

  : >"$home/Android/lineage-arm64/vda.raw"
  : >"$log"
  make_apk "$tmp/demo app.apk" lib/arm64-v8a/libdemo.so
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

  echo "PASS: dispatch"
}

case ${1:-all} in
  checker) test_checker ;;
  installer) test_installer ;;
  dispatch) test_dispatch ;;
  all) test_checker; test_installer; test_dispatch ;;
  *) fail "unknown test group: ${1:-}" ;;
esac
