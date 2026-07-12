#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") SERIAL [--abi arm64-v8a|armeabi-v7a] APK|APKM|XAPK|DIR" >&2
  exit 2
}

fail_input() {
  echo "[install] ERROR: $*" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
serial=$1
shift

abi=
if [[ ${1:-} == --abi ]]; then
  [[ $# -ge 3 ]] || usage
  abi=$2
  shift 2
fi
[[ $# -eq 1 ]] || usage
source=$1

case $abi in
  ""|arm64-v8a|armeabi-v7a) ;;
  *) fail_input "unsupported ABI '$abi' (use arm64-v8a or armeabi-v7a)" ;;
esac

command -v adb >/dev/null 2>&1 || {
  echo "[install] ERROR: adb not found" >&2
  exit 1
}

tmpdir=
cleanup() {
  if [[ -n $tmpdir ]]; then
    rm -rf -- "$tmpdir"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

declare -a apks=()

collect_apks() {
  local root=$1
  mapfile -d '' -t apks < <(find "$root" -type f -name '*.apk' -print0 | sort -z)
}

if [[ -d $source ]]; then
  collect_apks "$source"
elif [[ -f $source ]]; then
  lower_source=${source,,}
  case $lower_source in
    *.apk)
      apks=("$source")
      ;;
    *.apkm|*.xapk)
      command -v unzip >/dev/null 2>&1 || {
        echo "[install] ERROR: unzip not found" >&2
        exit 1
      }
      unzip -tqq "$source" >/dev/null 2>&1 || \
        fail_input "malformed bundle archive: $source"

      mapfile -t archive_entries < <(unzip -Z1 "$source")
      apk_entry_count=0
      for entry in "${archive_entries[@]}"; do
        normalized=${entry//\\//}
        if [[ $normalized == /* || /$normalized/ == */../* ]]; then
          fail_input "unsafe archive entry: $entry"
        fi
        if [[ $entry == *.apk ]]; then
          ((apk_entry_count += 1))
        fi
      done
      ((apk_entry_count > 0)) || fail_input "bundle contains no APK entries: $source"

      tmpdir=$(mktemp -d)
      unzip -qq "$source" '*.apk' -d "$tmpdir"
      collect_apks "$tmpdir"
      ;;
    *)
      fail_input "expected an .apk, .apkm, .xapk, or split directory: $source"
      ;;
  esac
else
  fail_input "input does not exist: $source"
fi

((${#apks[@]} > 0)) || fail_input "no APK files found in: $source"

has_arm64=0
has_arm32=0
has_x86_64=0
has_x86=0
declare -a apk_abi_sets=()
for apk in "${apks[@]}"; do
  unzip -tqq "$apk" >/dev/null 2>&1 || fail_input "malformed APK: $apk"
  name=${apk##*/}
  lower_name=${name,,}
  file_abis=()

  add_file_abi() {
    local candidate=$1 present
    for present in "${file_abis[@]}"; do
      [[ $present != "$candidate" ]] || return 0
    done
    file_abis+=("$candidate")
    case $candidate in
      arm64-v8a) has_arm64=1 ;;
      armeabi-v7a) has_arm32=1 ;;
      x86_64) has_x86_64=1 ;;
      x86) has_x86=1 ;;
    esac
  }

  case $lower_name in
    *arm64_v8a*|*arm64-v8a*)
      add_file_abi arm64-v8a
      ;;
    *armeabi_v7a*|*armeabi-v7a*)
      add_file_abi armeabi-v7a
      ;;
    *x86_64*|*x86-64*)
      add_file_abi x86_64
      ;;
    *x86*)
      add_file_abi x86
      ;;
  esac

  while IFS= read -r entry; do
    case $entry in
      lib/arm64-v8a/*) add_file_abi arm64-v8a ;;
      lib/armeabi-v7a/*) add_file_abi armeabi-v7a ;;
      lib/x86_64/*) add_file_abi x86_64 ;;
      lib/x86/*) add_file_abi x86 ;;
    esac
  done < <(unzip -Z1 "$apk")
  apk_abi_sets+=(" ${file_abis[*]} ")
done

if ((has_arm64 && has_arm32)) && [[ -z $abi ]]; then
  fail_input "bundle contains both ARM ABIs; select one with --abi arm64-v8a or --abi armeabi-v7a"
fi

native_present=$((has_arm64 || has_arm32 || has_x86_64 || has_x86))
effective_abi=$abi
if [[ -n $abi ]]; then
  requested_present=0
  if [[ $abi == arm64-v8a ]]; then
    requested_present=$has_arm64
  else
    requested_present=$has_arm32
  fi
  if ((native_present && ! requested_present)); then
    fail_input "requested ABI $abi is not present in the native APK set"
  fi
elif ((has_arm64)); then
  effective_abi=arm64-v8a
elif ((has_arm32)); then
  effective_abi=armeabi-v7a
elif ((native_present)); then
  fail_input "native APK set contains no supported ARM ABI"
fi

declare -a selected=()
for index in "${!apks[@]}"; do
  name=${apks[index]##*/}
  lower_name=${name,,}
  abi_set=${apk_abi_sets[index]}

  # Resource/noarch splits are architecture-neutral. Native APKs, including
  # multi-ABI features, are usable only when they contain the selected target.
  if [[ $abi_set == "  " ]]; then
    selected+=("${apks[index]}")
    continue
  fi
  if [[ -n $effective_abi && $abi_set == *" $effective_abi "* ]]; then
    selected+=("${apks[index]}")
  elif [[ $lower_name == base.apk ]]; then
    fail_input "base.apk is incompatible with target ABI $effective_abi (contains:${abi_set})"
  fi
done

((${#selected[@]} > 0)) || fail_input "no APK files remain after ABI filtering"

if ((${#selected[@]} == 1)); then
  adb_args=(-s "$serial" install -r)
else
  adb_args=(-s "$serial" install-multiple -r)
fi
if [[ -n $abi ]]; then
  adb_args+=(--abi "$abi")
fi
adb_args+=("${selected[@]}")

echo "[install] serial=$serial apks=${#selected[@]}${abi:+ abi=$abi}"
if adb "${adb_args[@]}"; then
  echo "[install] PASS"
else
  status=$?
  echo "[install] ERROR: adb install failed with status $status" >&2
  exit "$status"
fi
