#!/usr/bin/env bash
set -euo pipefail

readonly LINEAGE_BRANCH=lineage-23.2
readonly LINEAGE_TARGET=virtio_arm64
readonly LINEAGE_VARIANT=user
readonly LINEAGE_ABIS=arm64-v8a,armeabi-v7a,armeabi
readonly LINEAGE_ZYGOTE=zygote64_32
readonly LINEAGE_MANIFEST_URL=https://github.com/LineageOS/android.git
readonly AB_OTA_UPDATER_VALUE=false
readonly ROOMSERVICE_BRANCHES_VALUE='lineage-23.1 lineage-23.0'
readonly BUILDER_GIT_NAME='Declaw Multilib Builder'
readonly BUILDER_GIT_EMAIL=declaw-builder@localhost
readonly BUILDER_CHANGE_ID_KEY=Change-Id
readonly QEMU_IMG_PATH=/usr/bin/qemu-img

readonly BUILDER_REPO=https://github.com/jqssun/android-lineage-qemu.git
readonly BUILDER_REF=v2026.07.09
readonly BUILDER_COMMIT=54fc5dc82fa05778be15c1200240be53f707a542

readonly REPO_LAUNCHER_URL=https://storage.googleapis.com/git-repo-downloads/repo-2.54
readonly REPO_LAUNCHER_SHA256=6cba294d6218bbd4a1500598207b3979c752c7a122aef9429e4d7fef688833b5

readonly MIN_DISK_GIB=400
readonly MIN_RAM_GIB=64

BUILD_ROOT=${BUILD_ROOT:-$HOME/Android/lineage-multilib-build}
SOURCE_DIR=${LINEAGE_SOURCE_DIR:-$BUILD_ROOT/source}
BUILDER_DIR=${BUILDER_SNAPSHOT_DIR:-$BUILD_ROOT/builder-snapshot}
TOOLS_DIR=${BUILD_TOOLS_DIR:-$BUILD_ROOT/tools}
REPO_LAUNCHER=$TOOLS_DIR/repo
BUILD_GIT_CONFIG_GLOBAL=$BUILD_ROOT/gitconfig
BUILD_TIMESTAMP=${BUILD_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
DIST_DIR=${BUILD_DIST_DIR:-$BUILD_ROOT/dist/${BUILD_TIMESTAMP}-${LINEAGE_TARGET}}
BUILD_JOBS=${BUILD_JOBS:-}
BUILD_TMP_DIR=${BUILD_TMP_DIR:-$BUILD_ROOT/tmp}

die() {
  echo "[build] ERROR: $*" >&2
  exit 2
}

is_uint() {
  [[ $1 =~ ^[0-9]+$ ]]
}

default_build_jobs() {
  local cpus
  if [[ ${BUILD_TEST_MODE:-0} == 1 && -n ${BUILD_TEST_NPROC:-} ]]; then
    cpus=$BUILD_TEST_NPROC
  else
    cpus=$(nproc)
  fi
  is_uint "$cpus" && ((cpus > 0)) || die "could not determine a positive CPU count"
  if ((cpus > 4)); then
    cpus=4
  fi
  printf '%s\n' "$cpus"
}

validate_build_settings() {
  local normalized_tmp
  if [[ -z $BUILD_JOBS ]]; then
    BUILD_JOBS=$(default_build_jobs)
  fi
  is_uint "$BUILD_JOBS" && ((BUILD_JOBS > 0)) || \
    die "BUILD_JOBS must be a positive integer"

  [[ $BUILD_TMP_DIR == /* ]] || \
    die "BUILD_TMP_DIR must be an absolute non-root path"
  normalized_tmp=$(readlink -m -- "$BUILD_TMP_DIR")
  [[ $normalized_tmp != / ]] || \
    die "BUILD_TMP_DIR must be an absolute non-root path"
  BUILD_TMP_DIR=$normalized_tmp
}

activate_build_tmp() {
  mkdir -p -- "$BUILD_ROOT" "$BUILD_TMP_DIR"
  export TMPDIR=$BUILD_TMP_DIR
}

print_contract() {
  echo "[build] branch=$LINEAGE_BRANCH target=$LINEAGE_TARGET variant=$LINEAGE_VARIANT"
  echo "[build] abis=$LINEAGE_ABIS zygote=$LINEAGE_ZYGOTE"
  echo "[build] builder=$BUILDER_REPO ref=$BUILDER_REF commit=$BUILDER_COMMIT"
  echo "[build] manifest=$LINEAGE_MANIFEST_URL branch=$LINEAGE_BRANCH"
  echo "[build] repo=$REPO_LAUNCHER_URL sha256=$REPO_LAUNCHER_SHA256"
  echo "[build] root=$BUILD_ROOT"
  echo "[build] dist=$DIST_DIR"
  echo "[build] jobs=$BUILD_JOBS tmp=$BUILD_TMP_DIR"
}

print_build_commands() {
  echo "export PATH=$TOOLS_DIR:\$PATH"
  echo "export GIT_CONFIG_GLOBAL=$BUILD_GIT_CONFIG_GLOBAL"
  echo "export TMPDIR=$BUILD_TMP_DIR"
  echo "git lfs install --skip-repo"
  echo "git config --global user.name \"$BUILDER_GIT_NAME\""
  echo "git config --global user.email \"$BUILDER_GIT_EMAIL\""
  echo "git config --global trailer.changeid.key \"$BUILDER_CHANGE_ID_KEY\""
  echo "repo init -u $LINEAGE_MANIFEST_URL -b $LINEAGE_BRANCH --depth=1 --no-clone-bundle --git-lfs"
  echo "export AB_OTA_UPDATER=$AB_OTA_UPDATER_VALUE"
  echo "export ROOMSERVICE_BRANCHES=\"$ROOMSERVICE_BRANCHES_VALUE\""
  echo "source $SOURCE_DIR/build/envsetup.sh"
  echo "breakfast $LINEAGE_TARGET $LINEAGE_VARIANT"
  echo "m -j$BUILD_JOBS vm-utm-zip otapackage"
}

required_tools() {
  local -a tools=(
    awk bash bc bison ccache chmod cp curl date df dirname find flex free g++ gcc
    git git-lfs glslangValidator gperf grep java javac lz4 lzop m4 make meson
    mkdir mktemp mksquashfs mv ninja nproc perl pngcrush protoc python3 readlink
    rsync schedtool sed sha256sum sort unzip xsltproc zip
  )

  if [[ ${BUILD_TEST_MODE:-0} == 1 && -n ${BUILD_TEST_REQUIRED_TOOLS:-} ]]; then
    read -r -a tools <<<"$BUILD_TEST_REQUIRED_TOOLS"
  fi

  printf '%s\n' "${tools[@]}"
}

required_python_modules() {
  printf '%s\n' yaml google.protobuf mako
}

required_qemu_img_path() {
  if [[ ${BUILD_TEST_MODE:-0} == 1 && -n ${BUILD_TEST_QEMU_IMG_PATH:-} ]]; then
    printf '%s\n' "$BUILD_TEST_QEMU_IMG_PATH"
  else
    printf '%s\n' "$QEMU_IMG_PATH"
  fi
}

imagemagick_tools() {
  local -a tools=(magick convert)
  if [[ ${BUILD_TEST_MODE:-0} == 1 && -n ${BUILD_TEST_IMAGEMAGICK_TOOLS:-} ]]; then
    read -r -a tools <<<"$BUILD_TEST_IMAGEMAGICK_TOOLS"
  fi
  printf '%s\n' "${tools[@]}"
}

nearest_existing_path() {
  local path=$1 parent
  while [[ ! -e $path ]]; do
    parent=$(dirname -- "$path")
    [[ $parent != "$path" ]] || break
    path=$parent
  done
  printf '%s\n' "$path"
}

available_disk_gib() {
  local probe available_kib
  if [[ ${BUILD_TEST_MODE:-0} == 1 && -n ${BUILD_TEST_DISK_GIB:-} ]]; then
    is_uint "$BUILD_TEST_DISK_GIB" || die "BUILD_TEST_DISK_GIB must be an integer"
    printf '%s\n' "$BUILD_TEST_DISK_GIB"
    return
  fi

  probe=$(nearest_existing_path "$BUILD_ROOT")
  available_kib=$(df -Pk -- "$probe" | awk 'NR == 2 { print $4 }')
  is_uint "$available_kib" || die "could not determine free disk space for $probe"
  printf '%s\n' "$((available_kib / 1024 / 1024))"
}

available_ram_gib() {
  local available_kib
  if [[ ${BUILD_TEST_MODE:-0} == 1 && -n ${BUILD_TEST_RAM_GIB:-} ]]; then
    is_uint "$BUILD_TEST_RAM_GIB" || die "BUILD_TEST_RAM_GIB must be an integer"
    printf '%s\n' "$BUILD_TEST_RAM_GIB"
    return
  fi

  available_kib=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
  is_uint "$available_kib" || die "could not determine installed RAM"
  printf '%s\n' "$((available_kib / 1024 / 1024))"
}

preflight() {
  local tool module qemu_img disk_gib ram_gib failed=0 imagemagick_found=0

  while IFS= read -r tool; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "[build] ERROR: missing required host tool: $tool" >&2
      failed=1
    fi
  done < <(required_tools)

  qemu_img=$(required_qemu_img_path)
  if [[ ! -x $qemu_img ]]; then
    echo "[build] ERROR: missing required executable: $qemu_img" >&2
    failed=1
  fi

  while IFS= read -r tool; do
    if command -v "$tool" >/dev/null 2>&1; then
      imagemagick_found=1
      break
    fi
  done < <(imagemagick_tools)
  if ((imagemagick_found == 0)); then
    echo "[build] ERROR: missing ImageMagick command (need magick or convert)" >&2
    failed=1
  fi

  if [[ ! (${BUILD_TEST_MODE:-0} == 1 && \
           ${BUILD_TEST_SKIP_PYTHON_MODULES:-0} == 1) ]] && \
     command -v python3 >/dev/null 2>&1; then
    while IFS= read -r module; do
      if ! python3 - "$module" <<'PY'
import importlib
import sys

importlib.import_module(sys.argv[1])
PY
      then
        echo "[build] ERROR: missing required Python module: $module" >&2
        failed=1
      fi
    done < <(required_python_modules)
  fi

  ((failed == 0)) || exit 2

  disk_gib=$(available_disk_gib)
  ram_gib=$(available_ram_gib)

  if ((disk_gib < MIN_DISK_GIB)); then
    echo "[build] ERROR: $disk_gib GiB free; need at least $MIN_DISK_GIB GiB free" >&2
    failed=1
  fi
  if ((ram_gib < MIN_RAM_GIB)); then
    echo "[build] ERROR: $ram_gib GiB RAM; need at least $MIN_RAM_GIB GiB RAM" >&2
    failed=1
  fi

  if ((failed != 0)); then
    if [[ ${ALLOW_UNDERSIZED_BUILD:-0} != 1 ]]; then
      echo "[build] Set ALLOW_UNDERSIZED_BUILD=1 to accept a slow or space-constrained build." >&2
      exit 2
    fi
    echo "[build] WARNING: continuing with $disk_gib GiB free and $ram_gib GiB RAM" >&2
  fi

  echo "[build] preflight disk=${disk_gib}GiB ram=${ram_gib}GiB"
}

install_repo_launcher() {
  local download actual_sha
  mkdir -p -- "$TOOLS_DIR"
  download="$REPO_LAUNCHER.download"
  curl --fail --location --proto '=https' --tlsv1.2 \
    "$REPO_LAUNCHER_URL" --output "$download"
  actual_sha=$(sha256sum -- "$download" | awk '{ print $1 }')
  if [[ $actual_sha != "$REPO_LAUNCHER_SHA256" ]]; then
    rm -f -- "$download"
    die "repo launcher checksum mismatch (got $actual_sha)"
  fi
  chmod 0755 -- "$download"
  mv -f -- "$download" "$REPO_LAUNCHER"
}

configure_git_lfs() {
  export GIT_CONFIG_GLOBAL=$BUILD_GIT_CONFIG_GLOBAL
  git lfs install --skip-repo
  configure_git_identity
}

configure_git_identity() {
  mkdir -p -- "$(dirname -- "$BUILD_GIT_CONFIG_GLOBAL")"
  export GIT_CONFIG_GLOBAL=$BUILD_GIT_CONFIG_GLOBAL
  git config --global user.name "$BUILDER_GIT_NAME"
  git config --global user.email "$BUILDER_GIT_EMAIL"
  git config --global trailer.changeid.key "$BUILDER_CHANGE_ID_KEY"
}

prepare_builder_snapshot() {
  local actual_commit
  if [[ ! -e $BUILDER_DIR ]]; then
    git clone --depth 1 --branch "$BUILDER_REF" -- \
      "$BUILDER_REPO" "$BUILDER_DIR"
  elif [[ ! -d $BUILDER_DIR/.git ]]; then
    die "builder snapshot path exists but is not a git checkout: $BUILDER_DIR"
  fi

  actual_commit=$(git -C "$BUILDER_DIR" rev-parse HEAD)
  [[ $actual_commit == "$BUILDER_COMMIT" ]] || \
    die "builder snapshot is $actual_commit, expected $BUILDER_COMMIT"
}

sync_sources() {
  local jobs=${BUILD_SYNC_JOBS:-$(nproc)}
  is_uint "$jobs" && ((jobs > 0)) || die "BUILD_SYNC_JOBS must be a positive integer"

  mkdir -p -- "$SOURCE_DIR"
  (
    cd "$SOURCE_DIR"
    export PATH=$TOOLS_DIR:$PATH
    repo init -u "$LINEAGE_MANIFEST_URL" -b "$LINEAGE_BRANCH" \
      --depth=1 --no-clone-bundle --git-lfs
    repo sync --current-branch --no-tags --no-clone-bundle \
      --optimized-fetch --prune -j"$jobs"
  )
}

clean_target_artifacts() {
  local product_dir=$1 utm_dir path
  local -a utm_artifacts=()
  product_dir=${product_dir%/}
  [[ -n $product_dir && ${product_dir##*/} == "$LINEAGE_TARGET" ]] || \
    die "refusing artifact cleanup outside the $LINEAGE_TARGET product directory: $product_dir"
  utm_dir=$product_dir/VirtualMachine/UTM

  rm -f -- "$product_dir/lineage_${LINEAGE_TARGET}-ota.zip"
  if [[ -d $utm_dir ]]; then
    while IFS= read -r -d '' path; do
      utm_artifacts+=("$path")
    done < <(
      find "$utm_dir" -maxdepth 1 -name "UTM-VM-*-${LINEAGE_TARGET}.zip" \
        \( -type f -o -type l \) -print0
    )
  fi
  if ((${#utm_artifacts[@]} > 0)); then
    rm -f -- "${utm_artifacts[@]}"
  fi
}

build_target() {
  [[ -f $SOURCE_DIR/build/envsetup.sh ]] || \
    die "missing source environment: $SOURCE_DIR/build/envsetup.sh"

  (
    cd "$SOURCE_DIR"
    export PATH=$TOOLS_DIR:$PATH
    export AB_OTA_UPDATER=$AB_OTA_UPDATER_VALUE
    export ROOMSERVICE_BRANCHES=$ROOMSERVICE_BRANCHES_VALUE
    # Android's envsetup is not guaranteed to be nounset-clean.
    set +u
    # shellcheck disable=SC1091
    source build/envsetup.sh
    set -u
    breakfast "$LINEAGE_TARGET" "$LINEAGE_VARIANT"
    clean_target_artifacts "$SOURCE_DIR/out/target/product/$LINEAGE_TARGET"
    m -j"$BUILD_JOBS" vm-utm-zip otapackage
  )
}

single_artifact() {
  local product_dir=$1 pattern=$2 label=$3
  local -a matches=()
  if [[ -d $product_dir ]]; then
    mapfile -d '' -t matches < <(
      find "$product_dir" -maxdepth 1 -type f -name "$pattern" -print0 | sort -z
    )
  fi
  if ((${#matches[@]} != 1)); then
    die "expected exactly one $label matching $product_dir/$pattern; found ${#matches[@]}"
  fi
  printf '%s\n' "${matches[0]}"
}

find_utm_artifact() {
  single_artifact "$1/VirtualMachine/UTM" \
    "UTM-VM-*-${LINEAGE_TARGET}.zip" 'UTM ZIP'
}

find_ota_artifact() {
  single_artifact "$1" "lineage_${LINEAGE_TARGET}-ota.zip" 'OTA ZIP'
}

emit_dist() {
  local product_dir utm_zip ota_zip dist_parent stage builder_origin
  local utm_name ota_name
  product_dir="$SOURCE_DIR/out/target/product/$LINEAGE_TARGET"
  [[ -d $product_dir ]] || die "missing product output directory: $product_dir"

  utm_zip=$(find_utm_artifact "$product_dir")
  ota_zip=$(find_ota_artifact "$product_dir")
  utm_name=${utm_zip##*/}
  ota_name=${ota_zip##*/}

  [[ ! -e $DIST_DIR ]] || die "dist path already exists: $DIST_DIR"
  dist_parent=$(dirname -- "$DIST_DIR")
  mkdir -p -- "$dist_parent"
  stage=$(mktemp -d "$dist_parent/.multilib-dist.XXXXXX")
  cleanup_dist() {
    if [[ -n ${stage:-} && -d $stage ]]; then
      rm -rf -- "$stage"
    fi
  }
  trap cleanup_dist EXIT

  cp -- "$utm_zip" "$stage/$utm_name"
  cp -- "$ota_zip" "$stage/$ota_name"
  (
    cd "$SOURCE_DIR"
    "$REPO_LAUNCHER" manifest -r -o "$stage/lineage-manifest.xml"
  )

  builder_origin=$(git -C "$BUILDER_DIR" remote get-url origin)
  {
    printf 'repository=%s\n' "$builder_origin"
    printf 'reference=%s\n' "$BUILDER_REF"
    printf 'commit=%s\n' "$(git -C "$BUILDER_DIR" rev-parse HEAD)"
    printf 'note=%s\n' 'provenance snapshot only; upstream build.sh was not executed'
  } >"$stage/builder-provenance.txt"
  {
    printf 'created_utc=%s\n' "$BUILD_TIMESTAMP"
    printf 'manifest_url=%s\n' "$LINEAGE_MANIFEST_URL"
    printf 'branch=%s\n' "$LINEAGE_BRANCH"
    printf 'target=%s\n' "$LINEAGE_TARGET"
    printf 'variant=%s\n' "$LINEAGE_VARIANT"
    printf 'abis=%s\n' "$LINEAGE_ABIS"
    printf 'zygote=%s\n' "$LINEAGE_ZYGOTE"
    printf 'repo_launcher_url=%s\n' "$REPO_LAUNCHER_URL"
    printf 'repo_launcher_sha256=%s\n' "$REPO_LAUNCHER_SHA256"
    printf 'git_config_global=%s\n' "$BUILD_GIT_CONFIG_GLOBAL"
    printf 'ab_ota_updater=%s\n' "$AB_OTA_UPDATER_VALUE"
    printf 'roomservice_branches=%s\n' "$ROOMSERVICE_BRANCHES_VALUE"
  } >"$stage/build-metadata.txt"

  (
    cd "$stage"
    sha256sum -- "$utm_name" "$ota_name" lineage-manifest.xml \
      builder-provenance.txt build-metadata.txt >SHA256SUMS
  )

  mv -- "$stage" "$DIST_DIR"
  stage=
  trap - EXIT
  echo "[build] UTM=$DIST_DIR/$utm_name"
  echo "[build] OTA=$DIST_DIR/$ota_name"
  echo "[build] manifest=$DIST_DIR/lineage-manifest.xml"
  echo "[build] checksums=$DIST_DIR/SHA256SUMS"
}

main() {
  validate_build_settings
  print_contract
  if [[ ${BUILD_DRY_RUN:-0} == 1 ]]; then
    print_build_commands
    return 0
  fi

  preflight
  if [[ ${BUILD_PREFLIGHT_ONLY:-0} == 1 ]]; then
    echo "[build] preflight-only: PASS"
    return 0
  fi

  activate_build_tmp
  configure_git_lfs
  prepare_builder_snapshot
  install_repo_launcher
  sync_sources
  build_target
  emit_dist
  echo "[build] PASS: complete $LINEAGE_TARGET Android 16 artifacts are in $DIST_DIR"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
