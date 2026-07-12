#!/usr/bin/env bash
set -u

serial=${1:-}
if [[ -z $serial ]]; then
  echo "usage: check-multilib.sh SERIAL" >&2
  exit 1
fi

adb_for_device() {
  adb -s "$serial" "$@"
}

if ! state=$(adb_for_device get-state 2>/dev/null) || [[ $state != device ]]; then
  echo "[check] ERROR: adb device $serial is unreachable"
  exit 1
fi

adb_value() {
  adb_for_device "$@" 2>/dev/null | tr -d '\r'
}

release=$(adb_value shell getprop ro.build.version.release)
sdk=$(adb_value shell getprop ro.build.version.sdk)
kernel=$(adb_value shell uname -m)
uid=$(adb_value shell id -u)
selinux=$(adb_value shell getenforce)
zygote=$(adb_value shell getprop ro.zygote)
abilist64=$(adb_value shell getprop ro.product.cpu.abilist64)
abilist32=$(adb_value shell getprop ro.product.cpu.abilist32)
compat=$(adb_value shell sh -c \
  "if [ -r /proc/config.gz ]; then gzip -dc /proc/config.gz 2>/dev/null | grep -m1 '^CONFIG_COMPAT='; elif [ -r /proc/config ]; then grep -m1 '^CONFIG_COMPAT=' /proc/config; fi")

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
  local result_var=$1 path
  local report=()
  shift
  for path in "$@"; do
    if adb_for_device shell test -x "$path" >/dev/null 2>&1; then
      report+=("$path")
    else
      report+=("<missing:$path>")
      failures+=("missing executable $path")
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
if [[ -n $compat && $compat != CONFIG_COMPAT=y ]]; then
  failures+=("CONFIG_COMPAT=${compat#CONFIG_COMPAT=} (need y)")
fi

echo "[check] release=${release:-<empty>} sdk=${sdk:-<empty>} kernel=${kernel:-<empty>} uid=${uid:-<empty>} selinux=${selinux:-<empty>}"
echo "[check] zygote=${zygote:-<empty>}"
echo "[check] abilist64=${abilist64:-<empty>}"
echo "[check] abilist32=${abilist32:-<empty>}"
echo "[check] runtime64=$runtime64_report"
echo "[check] runtime32=$runtime32_report"
echo "[check] compat=${compat:-<unreadable>}"

if ((${#failures[@]})); then
  for failure in "${failures[@]}"; do
    echo "[check] FAIL: $failure"
  done
  echo "[check] FAIL: guest does not satisfy the ARM32 + ARM64 Android 16 contract"
  exit 2
fi

echo "[check] PASS: one Android 16 guest runs arm64-v8a and armeabi-v7a apps"
