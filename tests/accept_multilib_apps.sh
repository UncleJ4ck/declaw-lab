#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECKER="$ROOT/avd/check-multilib.sh"
INSTALLER="$ROOT/avd/install-app.sh"

usage() {
  echo "usage: $(basename "$0") --serial SERIAL --x X.apkm --instagram INSTAGRAM.apkm" >&2
  exit 2
}

input_error() {
  echo "[accept] ERROR: $*" >&2
  exit 2
}

runtime_error() {
  echo "[accept] ERROR: $*" >&2
  exit 1
}

serial=
x_source=
instagram_source=
while (($#)); do
  case $1 in
    --serial)
      (($# >= 2)) || usage
      serial=$2
      shift 2
      ;;
    --x)
      (($# >= 2)) || usage
      x_source=$2
      shift 2
      ;;
    --instagram)
      (($# >= 2)) || usage
      instagram_source=$2
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      input_error "unknown argument: $1"
      ;;
  esac
done

[[ -n $serial && -n $x_source && -n $instagram_source ]] || usage
for source in "$x_source" "$instagram_source"; do
  [[ -f $source ]] || input_error "bundle not found: $source"
  [[ ${source,,} == *.apkm ]] || input_error "expected an APKM bundle: $source"
done

poll_attempts=${ACCEPT_POLL_ATTEMPTS:-20}
poll_interval=${ACCEPT_POLL_INTERVAL:-1}
adb_timeout=${ACCEPT_ADB_TIMEOUT:-15}
[[ $poll_attempts =~ ^[1-9][0-9]*$ ]] || \
  input_error "ACCEPT_POLL_ATTEMPTS must be a positive integer"
[[ $poll_interval =~ ^[0-9]+([.][0-9]+)?$ ]] || \
  input_error "ACCEPT_POLL_INTERVAL must be a non-negative number"
[[ $adb_timeout =~ ^[0-9]+([.][0-9]+)?[smhd]?$ ]] || \
  input_error "ACCEPT_ADB_TIMEOUT has an invalid timeout value"

for command in adb cp mktemp python3 sha256sum sort timeout; do
  command -v "$command" >/dev/null 2>&1 || \
    runtime_error "required host command not found: $command"
done
[[ -x $CHECKER ]] || runtime_error "multilib checker is not executable: $CHECKER"
[[ -x $INSTALLER ]] || runtime_error "production installer is not executable: $INSTALLER"

tmpdir=$(mktemp -d)
cleanup() {
  rm -rf -- "$tmpdir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Work from one private copy of each operator-supplied bundle. This binds metadata,
# hashes, selected splits, and the bytes passed to the production installer to the
# same immutable input even if the Downloads copy changes during a long TCG run.
x_bundle="$tmpdir/x.apkm"
instagram_bundle="$tmpdir/instagram.apkm"
cp -- "$x_source" "$x_bundle"
cp -- "$instagram_source" "$instagram_bundle"

inspect_bundle() {
  local bundle=$1 expected_package=$2 expected_abi=$3 output=$4
  python3 - "$bundle" "$expected_package" "$expected_abi" >"$output" <<'PY'
import io
import json
import pathlib
import posixpath
import stat
import sys
import zipfile

bundle = pathlib.Path(sys.argv[1])
expected_package = sys.argv[2]
expected_abi = sys.argv[3]


def fail(message):
    print(f"[accept] ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


def metadata_value(metadata, keys, label):
    for key in keys:
        value = metadata.get(key)
        if value is not None and str(value).strip():
            value = str(value).strip()
            if "\n" in value or "\r" in value:
                fail(f"info.json {label} contains a newline")
            return value
    fail(f"info.json has no {label}")


def entry_abis(name, contents):
    lower_name = pathlib.PurePosixPath(name).name.lower()
    found = set()
    filename_markers = {
        "arm64-v8a": ("arm64_v8a", "arm64-v8a"),
        "armeabi-v7a": ("armeabi_v7a", "armeabi-v7a"),
        "x86_64": ("x86_64", "x86-64"),
        "x86": ("x86",),
    }
    for abi, markers in filename_markers.items():
        if any(marker in lower_name for marker in markers):
            found.add(abi)
    try:
        with zipfile.ZipFile(io.BytesIO(contents)) as apk:
            if apk.testzip() is not None:
                fail(f"malformed APK entry: {name}")
            for apk_name in apk.namelist():
                for abi in ("arm64-v8a", "armeabi-v7a", "x86_64", "x86"):
                    if apk_name.startswith(f"lib/{abi}/"):
                        found.add(abi)
    except zipfile.BadZipFile:
        fail(f"malformed APK entry: {name}")
    return found


try:
    archive = zipfile.ZipFile(bundle)
except (OSError, zipfile.BadZipFile) as error:
    fail(f"malformed APKM bundle {bundle}: {error}")

with archive:
    bad_crc = archive.testzip()
    if bad_crc is not None:
        fail(f"APKM CRC check failed for entry: {bad_crc}")

    normalized = {}
    for member in archive.infolist():
        name = member.filename
        if "\\" in name or name.startswith("/"):
            fail(f"unsafe APKM entry: {name}")
        clean = posixpath.normpath(name)
        if clean in ("", ".", "..") or clean.startswith("../"):
            fail(f"unsafe APKM entry: {name}")
        if clean in normalized:
            fail(f"duplicate normalized APKM entry: {clean}")
        normalized[clean] = member
        mode = member.external_attr >> 16
        kind = stat.S_IFMT(mode)
        if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
            fail(f"special APKM entry is not allowed: {name}")

    info_members = [member for name, member in normalized.items() if name == "info.json"]
    if len(info_members) != 1:
        fail("APKM must contain exactly one root info.json")
    try:
        metadata = json.loads(archive.read(info_members[0]))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid info.json: {error}")
    if not isinstance(metadata, dict):
        fail("info.json must contain a JSON object")

    package = metadata_value(
        metadata, ("package_name", "packageName", "package", "pname"), "package name"
    )
    version_code = metadata_value(
        metadata, ("version_code", "versionCode", "versioncode"), "version code"
    )
    version_name = metadata_value(
        metadata,
        ("version_name", "versionName", "release_version", "version"),
        "version name",
    )
    if package != expected_package:
        fail(f"expected package {expected_package}, info.json declares {package}")
    if not version_code.isdecimal():
        fail(f"info.json version code is not decimal: {version_code}")

    apk_members = [
        (name, member)
        for name, member in normalized.items()
        if name.lower().endswith(".apk") and not member.is_dir()
    ]
    if not apk_members:
        fail("APKM contains no APK entries")
    basenames = [pathlib.PurePosixPath(name).name for name, _ in apk_members]
    if len(basenames) != len(set(basenames)):
        fail("APKM contains duplicate APK basenames")
    if basenames.count("base.apk") != 1:
        fail("APKM must contain exactly one base.apk")

    entries = []
    all_native_abis = set()
    for name, member in apk_members:
        abis = entry_abis(name, archive.read(member))
        all_native_abis.update(abis)
        entries.append((pathlib.PurePosixPath(name).name, abis))
    if expected_abi not in all_native_abis:
        fail(f"bundle {bundle} does not contain native ABI {expected_abi}")

    selected = []
    for basename, abis in entries:
        if not abis or expected_abi in abis:
            selected.append(basename)
        elif basename == "base.apk":
            fail(f"base.apk is incompatible with required ABI {expected_abi}")
    if "base.apk" not in selected:
        fail("ABI filtering removed base.apk")
    selected.sort()

print(package)
print(version_code)
print(version_name)
print(",".join(selected))
PY
}

x_meta="$tmpdir/x.meta"
instagram_meta="$tmpdir/instagram.meta"
inspect_bundle "$x_bundle" com.twitter.android arm64-v8a "$x_meta"
inspect_bundle "$instagram_bundle" com.instagram.android armeabi-v7a "$instagram_meta"
mapfile -t x_fields <"$x_meta"
mapfile -t instagram_fields <"$instagram_meta"
[[ ${#x_fields[@]} -eq 4 && ${#instagram_fields[@]} -eq 4 ]] || \
  input_error "internal bundle inspection returned incomplete metadata"

x_version=${x_fields[1]}
x_version_name=${x_fields[2]}
x_splits=${x_fields[3]}
instagram_version=${instagram_fields[1]}
instagram_version_name=${instagram_fields[2]}
instagram_splits=${instagram_fields[3]}
x_sha=$(sha256sum "$x_bundle" | awk '{print $1}')
instagram_sha=$(sha256sum "$instagram_bundle" | awk '{print $1}')

echo "[accept] bundle package=com.twitter.android abi=arm64-v8a versionCode=$x_version versionName=$x_version_name sha256=$x_sha splits=$x_splits"
echo "[accept] bundle package=com.instagram.android abi=armeabi-v7a versionCode=$instagram_version versionName=$instagram_version_name sha256=$instagram_sha splits=$instagram_splits"

set +e
CHECK_ADB_TIMEOUT="$adb_timeout" "$CHECKER" "$serial"
checker_status=$?
set -e
((checker_status == 0)) || exit "$checker_status"

adb_for_device() {
  timeout --kill-after=1 "$adb_timeout" adb -s "$serial" "$@"
}

adb_capture() {
  local result_var=$1 label=$2 output status
  shift 2
  set +e
  output=$(adb_for_device "$@" 2>&1)
  status=$?
  set -e
  if ((status == 124 || status == 137)); then
    runtime_error "adb timed out while $label"
  elif ((status != 0)); then
    runtime_error "adb failed while $label (status $status): $output"
  fi
  output=${output//$'\r'/}
  printf -v "$result_var" '%s' "$output"
}

adb_run() {
  local label=$1 status
  shift
  set +e
  adb_for_device "$@"
  status=$?
  set -e
  if ((status == 124 || status == 137)); then
    runtime_error "adb timed out while $label"
  elif ((status != 0)); then
    runtime_error "adb failed while $label (status $status)"
  fi
}

read_boot_id() {
  local result_var=$1 value
  adb_capture value "reading guest boot ID" shell cat /proc/sys/kernel/random/boot_id
  [[ -n $value ]] || runtime_error "guest returned an empty boot ID"
  [[ $value != *$'\n'* && $value != *' '* ]] || \
    runtime_error "guest returned an invalid boot ID: $value"
  printf -v "$result_var" '%s' "$value"
}

initial_boot_id=
read_boot_id initial_boot_id
echo "[accept] boot_id=$initial_boot_id"

assert_same_boot() {
  local label=$1 current_boot_id
  read_boot_id current_boot_id
  [[ $current_boot_id == "$initial_boot_id" ]] || \
    runtime_error "guest boot ID changed $label: $initial_boot_id -> $current_boot_id"
}

verify_installed_package() {
  local package=$1 expected_version=$2 expected_abi=$3 expected_splits=$4
  local dump paths version abi line path basename actual_splits
  local -a versions=() abis=() actual=() sorted=()
  adb_capture dump "reading installed metadata for $package" shell dumpsys package "$package"
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*versionCode=([0-9]+)([[:space:]]|$) ]]; then
      versions+=("${BASH_REMATCH[1]}")
    elif [[ $line =~ ^[[:space:]]*primaryCpuAbi=([^[:space:]]+) ]]; then
      abis+=("${BASH_REMATCH[1]}")
    fi
  done <<<"$dump"
  ((${#versions[@]} > 0)) || \
    runtime_error "could not determine one installed versionCode for $package"
  ((${#abis[@]} > 0)) || \
    runtime_error "could not determine one primaryCpuAbi for $package"
  mapfile -t versions < <(printf '%s\n' "${versions[@]}" | sort -u)
  mapfile -t abis < <(printf '%s\n' "${abis[@]}" | sort -u)
  [[ ${#versions[@]} -eq 1 ]] || \
    runtime_error "could not determine one installed versionCode for $package"
  [[ ${#abis[@]} -eq 1 ]] || \
    runtime_error "could not determine one primaryCpuAbi for $package"
  version=${versions[0]}
  abi=${abis[0]}
  [[ $version == "$expected_version" ]] || \
    runtime_error "$package versionCode=$version (expected $expected_version)"
  [[ $abi == "$expected_abi" ]] || \
    runtime_error "$package primaryCpuAbi=$abi (expected $expected_abi)"

  adb_capture paths "reading installed split paths for $package" shell pm path "$package"
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    [[ $line == package:* ]] || \
      runtime_error "unexpected pm path output for $package: $line"
    path=${line#package:}
    basename=${path##*/}
    [[ -n $basename && $basename == *.apk ]] || \
      runtime_error "invalid installed APK path for $package: $line"
    actual+=("$basename")
  done <<<"$paths"
  ((${#actual[@]} > 0)) || runtime_error "pm path returned no APKs for $package"
  mapfile -t sorted < <(printf '%s\n' "${actual[@]}" | sort -u)
  [[ ${#sorted[@]} -eq ${#actual[@]} ]] || \
    runtime_error "pm path returned duplicate APK basenames for $package"
  actual_splits=$(IFS=,; echo "${sorted[*]}")
  [[ $actual_splits == "$expected_splits" ]] || \
    runtime_error "$package installed splits do not match supplied bundle: actual=$actual_splits expected=$expected_splits"
}

resolve_launcher() {
  local result_var=$1 package=$2 resolved line resolved_component=
  adb_capture resolved "resolving enabled launcher for $package" \
    shell cmd package resolve-activity --brief --components --user 0 \
    -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p "$package"
  while IFS= read -r line; do
    if [[ $line == "$package/"* && $line != *[[:space:]]* ]]; then
      resolved_component=$line
    fi
  done <<<"$resolved"
  [[ -n $resolved_component ]] || \
    runtime_error "no enabled launcher activity resolved for $package: $resolved"
  printf -v "$result_var" '%s' "$resolved_component"
}

wait_for_main_process() {
  local result_pid_var=$1 result_exe_var=$2 package=$3 expected_exe=$4
  local previous_pid='' observed_pid='' observed_exe='' attempt=0
  local stable_pid='' stable_exe=''
  for ((attempt = 1; attempt <= poll_attempts; attempt += 1)); do
    adb_capture observed_pid "polling main PID for $package" shell pidof "$package"
    observed_pid=${observed_pid//$'\n'/ }
    if [[ $observed_pid =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
      observed_pid=${BASH_REMATCH[1]}
      adb_capture observed_exe "reading executable for $package pid $observed_pid" \
        shell readlink "/proc/$observed_pid/exe"
      if [[ $observed_pid == "$previous_pid" ]]; then
        stable_pid=$observed_pid
        stable_exe=$observed_exe
        break
      fi
      previous_pid=$observed_pid
    else
      previous_pid=
    fi
    sleep "$poll_interval"
  done
  [[ -n $stable_pid ]] || runtime_error "stable main PID not found for $package"
  [[ $stable_exe == "$expected_exe" ]] || \
    runtime_error "$package exe=$stable_exe (expected $expected_exe)"
  printf -v "$result_pid_var" '%s' "$stable_pid"
  printf -v "$result_exe_var" '%s' "$stable_exe"
}

scan_native_failures() {
  local package=$1 logs bad
  adb_capture logs "reading controlled logcat for $package" shell logcat -d -v brief
  bad=$(grep -E \
    'INSTALL_FAILED_NO_MATCHING_ABIS|UnsatisfiedLinkError|CANNOT LINK EXECUTABLE' \
    <<<"$logs" || true)
  if [[ -n $bad ]]; then
    echo "[accept] ERROR: native ABI/linker failure while launching $package" >&2
    printf '%s\n' "$bad" >&2
    exit 1
  fi
}

accept_app() {
  local package=$1 abi=$2 expected_exe=$3 bundle=$4 version=$5 splits=$6
  local component pid exe install_status start_output

  set +e
  "$INSTALLER" "$serial" --abi "$abi" "$bundle"
  install_status=$?
  set -e
  ((install_status == 0)) || exit "$install_status"

  verify_installed_package "$package" "$version" "$abi" "$splits"
  resolve_launcher component "$package"
  adb_run "clearing controlled logcat for $package" shell logcat -c
  adb_run "force-stopping $package" shell am force-stop "$package"
  adb_capture start_output "launching $component" shell am start -W -n "$component"
  grep -Fq -- 'Status: ok' <<<"$start_output" || \
    runtime_error "launcher did not report Status: ok for $package: $start_output"
  wait_for_main_process pid exe "$package" "$expected_exe"
  scan_native_failures "$package"
  assert_same_boot "after launching $package"
  echo "[accept] process package=$package pid=$pid exe=$exe"
  echo "[accept] PASS package=$package abi=$abi exe=$exe"
}

accept_app com.twitter.android arm64-v8a /system/bin/app_process64 \
  "$x_bundle" "$x_version" "$x_splits"
accept_app com.instagram.android armeabi-v7a /system/bin/app_process32 \
  "$instagram_bundle" "$instagram_version" "$instagram_splits"
assert_same_boot "at final acceptance"
echo "[accept] PASS: both architectures launched during the same guest boot"
