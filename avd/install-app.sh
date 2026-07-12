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
declare -a filename_abis=()
for apk in "${apks[@]}"; do
  unzip -tqq "$apk" >/dev/null 2>&1 || fail_input "malformed APK: $apk"
  name=${apk##*/}
  lower_name=${name,,}
  filename_abi=
  case $lower_name in
    *arm64_v8a*|*arm64-v8a*)
      filename_abi=arm64-v8a
      has_arm64=1
      ;;
    *armeabi_v7a*|*armeabi-v7a*)
      filename_abi=armeabi-v7a
      has_arm32=1
      ;;
  esac
  filename_abis+=("$filename_abi")

  while IFS= read -r entry; do
    case $entry in
      lib/arm64-v8a/*) has_arm64=1 ;;
      lib/armeabi-v7a/*) has_arm32=1 ;;
    esac
  done < <(unzip -Z1 "$apk")
done

if ((has_arm64 && has_arm32)) && [[ -z $abi ]]; then
  fail_input "bundle contains both ARM ABIs; select one with --abi arm64-v8a or --abi armeabi-v7a"
fi

declare -a selected=()
for index in "${!apks[@]}"; do
  if [[ -n $abi && -n ${filename_abis[index]} && ${filename_abis[index]} != "$abi" ]]; then
    continue
  fi
  selected+=("${apks[index]}")
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
