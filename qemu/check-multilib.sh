#!/usr/bin/env bash
set -u

serial=${1:-}
if [[ -z $serial ]]; then
  echo "usage: check-multilib.sh SERIAL" >&2
  exit 1
fi

adb_timeout=${CHECK_ADB_TIMEOUT:-10}
if [[ ! $adb_timeout =~ ^[0-9]+([.][0-9]+)?[smhd]?$ ]]; then
  echo "[check] ERROR: invalid CHECK_ADB_TIMEOUT=$adb_timeout" >&2
  exit 1
fi
if ! command -v timeout >/dev/null 2>&1; then
  echo "[check] ERROR: host timeout command is required" >&2
  exit 1
fi

adb_for_device() {
  timeout --kill-after=1 "$adb_timeout" adb -s "$serial" "$@"
}

state=$(adb_for_device get-state 2>/dev/null)
status=$?
if [[ $status -eq 124 || $status -eq 137 ]]; then
  echo "[check] ERROR: adb command timed out while checking device $serial"
  exit 1
fi
if [[ $status -ne 0 || $state != device ]]; then
  echo "[check] ERROR: adb device $serial is unreachable"
  exit 1
fi

transport_error() {
  local label=$1 status=$2
  if [[ $status -eq 124 || $status -eq 137 ]]; then
    echo "[check] ERROR: adb command timed out while $label"
  else
    echo "[check] ERROR: adb command failed while $label"
  fi
  exit 1
}

adb_capture() {
  local result_var=$1 label=$2 output status
  shift 2
  output=$(adb_for_device "$@" 2>/dev/null)
  status=$?
  [[ $status -eq 0 ]] || transport_error "$label" "$status"
  output=${output//$'\r'/}
  printf -v "$result_var" '%s' "$output"
}

release=''
sdk=''
kernel=''
uid=''
selinux=''
zygote=''
abilist64=''
abilist32=''
compat=''
adb_capture release "reading ro.build.version.release" shell getprop ro.build.version.release
adb_capture sdk "reading ro.build.version.sdk" shell getprop ro.build.version.sdk
adb_capture kernel "reading kernel architecture" shell uname -m
adb_capture uid "reading shell uid" shell id -u
adb_capture selinux "reading SELinux mode" shell getenforce
adb_capture zygote "reading ro.zygote" shell getprop ro.zygote
adb_capture abilist64 "reading ro.product.cpu.abilist64" shell getprop ro.product.cpu.abilist64
adb_capture abilist32 "reading ro.product.cpu.abilist32" shell getprop ro.product.cpu.abilist32
# This program is intentionally expanded by the Android guest's shell.
# shellcheck disable=SC2016
compat_command='config=; if [ -r /proc/config.gz ]; then config=$(gzip -dc /proc/config.gz 2>/dev/null | grep -m1 -E "^(CONFIG_COMPAT=|# CONFIG_COMPAT is not set$)" || true); elif [ -r /proc/config ]; then config=$(grep -m1 -E "^(CONFIG_COMPAT=|# CONFIG_COMPAT is not set$)" /proc/config || true); fi; if [ -n "$config" ]; then printf "%s\n" "$config"; else echo "<unreadable>"; fi'
adb_capture compat "reading CONFIG_COMPAT" shell "$compat_command"

runtime64=(
  /system/bin/app_process64
  /apex/com.android.runtime/bin/linker64
)
runtime32=(
  /system/bin/app_process32
  /apex/com.android.runtime/bin/linker
)
failures=()

has_abi() {
  local list=$1 required=$2
  [[ ",$list," == *",$required,"* ]]
}

runtime_report() {
  local result_var=$1 path state runtime_command
  local report=()
  shift
  for path in "$@"; do
    state=
    runtime_command="if [ -x '$path' ]; then echo executable; else echo missing; fi"
    adb_capture state "checking executable $path" shell "$runtime_command"
    if [[ $state == executable ]]; then
      report+=("$path")
    elif [[ $state == missing ]]; then
      report+=("<missing:$path>")
      failures+=("missing executable $path")
    else
      echo "[check] ERROR: unexpected response while checking executable $path"
      exit 1
    fi
  done
  local IFS=,
  printf -v "$result_var" '%s' "${report[*]}"
}

runtime64_report=
runtime32_report=
runtime_report runtime64_report "${runtime64[@]}"
runtime_report runtime32_report "${runtime32[@]}"

[[ $release == 16 ]] || failures+=("Android release=${release:-<empty>} (need 16)")
[[ $sdk == 36 ]] || failures+=("Android SDK=${sdk:-<empty>} (need 36)")
[[ $kernel == aarch64 ]] || failures+=("kernel=${kernel:-<empty>} (need aarch64)")
[[ $uid == 0 ]] || failures+=("uid=${uid:-<empty>} (need 0)")
[[ $selinux == Permissive ]] || failures+=("SELinux=${selinux:-<empty>} (need Permissive)")
[[ $zygote == zygote64_32 ]] || failures+=("ro.zygote=${zygote:-<empty>} (need zygote64_32)")
has_abi "$abilist64" arm64-v8a || failures+=("abilist64=${abilist64:-<empty>} (need arm64-v8a)")
if ! has_abi "$abilist32" armeabi-v7a || ! has_abi "$abilist32" armeabi; then
  failures+=("abilist32=${abilist32:-<empty>} (need armeabi-v7a,armeabi)")
fi
compat_proof=
if [[ $compat == "# CONFIG_COMPAT is not set" ]]; then
  failures+=("CONFIG_COMPAT is disabled (need y)")
elif [[ $compat == "<unreadable>" || -z $compat ]]; then
  probe=
  # This program is intentionally expanded by the Android guest's shell.
  # shellcheck disable=SC2016
  probe_command='/apex/com.android.runtime/bin/linker --help >/dev/null 2>&1; printf "status=%s\n" "$?"'
  adb_capture probe "probing 32-bit runtime execution" shell "$probe_command"
  if [[ $probe == status=0 ]]; then
    compat_proof="runtime-probed:/apex/com.android.runtime/bin/linker --help"
  elif [[ $probe == status=* ]]; then
    failures+=("CONFIG_COMPAT unavailable and 32-bit runtime probe failed")
  else
    echo "[check] ERROR: unexpected response while probing 32-bit runtime execution"
    exit 1
  fi
elif [[ $compat != CONFIG_COMPAT=y ]]; then
  failures+=("CONFIG_COMPAT=${compat#CONFIG_COMPAT=} (need y)")
fi

echo "[check] release=${release:-<empty>} sdk=${sdk:-<empty>} kernel=${kernel:-<empty>} uid=${uid:-<empty>} selinux=${selinux:-<empty>}"
echo "[check] zygote=${zygote:-<empty>}"
echo "[check] abilist64=${abilist64:-<empty>}"
echo "[check] abilist32=${abilist32:-<empty>}"
echo "[check] runtime64=$runtime64_report"
echo "[check] runtime32=$runtime32_report"
echo "[check] compat=${compat:-<unreadable>}"
if [[ -n $compat_proof ]]; then
  echo "[check] compat-proof=$compat_proof"
fi

if ((${#failures[@]})); then
  for failure in "${failures[@]}"; do
    echo "[check] FAIL: $failure"
  done
  echo "[check] FAIL: guest does not satisfy the ARM32 + ARM64 Android 16 contract"
  exit 2
fi

echo "[check] PASS: one Android 16 guest runs arm64-v8a and armeabi-v7a apps"
