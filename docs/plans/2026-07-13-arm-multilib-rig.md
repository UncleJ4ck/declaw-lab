# ARM32 + ARM64 Android Rig Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build and validate one rooted Android 16 QEMU guest that runs both ARM64 and ARMv7 application processes.

**Architecture:** Rebuild the proven LineageOS virtio image with the official `virtio_arm64` multilib product instead of `virtio_arm64only`. Preserve the current QEMU/UEFI boot stack, add fail-closed runtime capability checks and APKM-aware installation, then prove an arm64 app and an arm32 app launch under their respective 64-bit and 32-bit Zygotes in one boot.

**Tech Stack:** Bash, LineageOS 23.2/AOSP build system, repo, QEMU TCG, adb, Python standard-library ZIP fixtures, scrcpy.

---

### Task 1: Add the deterministic test harness and live ABI checker

**Files:**
- Create: `tests/test_multilib_lab.sh`
- Create: `tests/fakes/adb`
- Create: `avd/check-multilib.sh`

**Step 1: Write the failing checker tests**

Create a fake `adb` with `multilib`, `arm64only`, `missing-runtime`, and
`unreachable` profiles. Assert exact normalized output and exit codes for:

```text
[check] zygote=zygote64_32
[check] abilist64=arm64-v8a
[check] abilist32=armeabi-v7a,armeabi
[check] PASS: one Android 16 guest runs arm64-v8a and armeabi-v7a apps
```

The arm64-only profile must exit 2 and report the missing Zygote, ABI, app
process, and linker. An unreachable device exits 1.

**Step 2: Run the test to verify it fails**

Run: `bash tests/test_multilib_lab.sh checker`
Expected: FAIL because `avd/check-multilib.sh` does not exist.

**Step 3: Implement the minimal checker**

Implement `check-multilib.sh SERIAL` using one explicit adb serial. Collect
release, SDK, kernel, uid, SELinux, Zygote, ABI lists, executable runtime files,
and `CONFIG_COMPAT`. Print every failure, then a final PASS or FAIL summary.

**Step 4: Run the checker tests**

Run: `bash tests/test_multilib_lab.sh checker`
Expected: PASS for all checker profiles.

**Step 5: Commit**

```bash
git add tests/test_multilib_lab.sh tests/fakes/adb avd/check-multilib.sh
git commit -m "test: define the ARM32 and ARM64 guest contract"
```

### Task 2: Add APK, split-directory, and APKM installation

**Files:**
- Create: `avd/install-app.sh`
- Modify: `tests/test_multilib_lab.sh`
- Modify: `tests/fakes/adb`

**Step 1: Write failing installer tests**

Generate tiny APK/APKM fixtures and assert:

```bash
avd/install-app.sh localhost:6555 demo.apk
shared/install-app.sh localhost:6555 "arm64 bundle/"
shared/install-app.sh localhost:6555 arm32-app.apkm
avd/install-app.sh localhost:6555 --abi armeabi-v7a mixed.apkm
```

Check preserved arguments, APK-only extraction, explicit ABI forwarding,
mixed-ABI rejection without `--abi`, and nonzero exits for empty/malformed
inputs and adb failures.

**Step 2: Run the tests to verify they fail**

Run: `bash tests/test_multilib_lab.sh installer`
Expected: FAIL because `avd/install-app.sh` does not exist.

**Step 3: Implement the minimal installer**

Use Bash arrays for every adb argument. Extract APKM/XAPK ZIPs under `mktemp -d`
with a cleanup trap. Discover ABI config splits by filename and APK ZIP entries;
if both ARM architectures are present, require `--abi` and filter the other ABI
split. Never pass non-APK archive entries to adb.

**Step 4: Run the installer tests**

Run: `bash tests/test_multilib_lab.sh installer`
Expected: PASS.

**Step 5: Commit**

```bash
git add avd/install-app.sh tests/test_multilib_lab.sh tests/fakes/adb
git commit -m "feat: install APKM bundles for either ARM ABI"
```

### Task 3: Wire check/install into the public lab CLI

**Files:**
- Modify: `avd/lab`
- Modify: `tests/test_multilib_lab.sh`

**Step 1: Write failing dispatch tests**

Assert that `lab qemu check`, `lab qemu install`, and the existing
`lab qemu keylog` are recognized commands. `check` must inspect an already
running guest without booting or downloading. `install` must ensure/check the
guest before calling the installer. Capture installation must reuse the same
installer so `.apkm` works in the pentest one-liner.

**Step 2: Run the dispatch tests to verify they fail**

Run: `bash tests/test_multilib_lab.sh dispatch`
Expected: FAIL because `check`/`install` are parsed as bare `go` targets and
`keylog` is currently omitted from the known-command parser.

**Step 3: Implement minimal CLI integration**

Add `keylog|check|install` to command parsing. Add qemu dispatch handlers, make
`qemu_status` include both ABI lists/Zygote, and route all local app paths
through `install-app.sh`.

**Step 4: Run dispatch and regression tests**

Run: `bash tests/test_multilib_lab.sh dispatch`
Expected: PASS with no fake boot/download command invoked.

Run: `bash tests/test_multilib_lab.sh`
Expected: PASS.

**Step 5: Commit**

```bash
git add avd/lab tests/test_multilib_lab.sh
git commit -m "feat: expose multilib checks and bundle install in lab"
```

### Task 4: Add a pinned LineageOS multilib builder

**Files:**
- Create: `avd/build-lineage-multilib.sh`
- Modify: `tests/test_multilib_lab.sh`
- Modify: `.gitignore`

**Step 1: Write failing build-plan tests**

Run the builder with `BUILD_DRY_RUN=1` and assert it declares:

```text
[build] branch=lineage-23.2 target=virtio_arm64 variant=user
[build] abis=arm64-v8a,armeabi-v7a,armeabi zygote=zygote64_32
breakfast virtio_arm64 user
m vm-utm-zip otapackage
```

Reject any generated command or path containing `virtio_arm64only`. Assert the
real path checks required tools and available disk before syncing.

**Step 2: Run the test to verify it fails**

Run: `bash tests/test_multilib_lab.sh build`
Expected: FAIL because the builder does not exist.

**Step 3: Implement the builder**

Pin the jqssun builder repository commit, sync LineageOS 23.2 shallowly into a
configurable build root, build only `virtio_arm64`, emit the UTM ZIP, OTA ZIP,
`repo manifest -r`, source commit metadata, and SHA-256 checksums into a
timestamped dist directory. Do not build x86 or `arm64only` artifacts.

**Step 4: Run the build-plan tests**

Run: `bash tests/test_multilib_lab.sh build`
Expected: PASS without network or source checkout.

**Step 5: Commit**

```bash
git add .gitignore avd/build-lineage-multilib.sh tests/test_multilib_lab.sh
git commit -m "build: produce the Lineage Android 16 multilib image"
```

### Task 5: Provision only complete multilib artifacts

**Files:**
- Modify: `avd/provision.sh`
- Modify: `avd/boot-arm64.sh`
- Modify: `tests/test_multilib_lab.sh`

**Step 1: Write failing provisioning tests**

With `PROVISION_DRY_RUN=1`, assert the provisioner accepts an explicit
`virtio_arm64` ZIP, rejects an `arm64only` ZIP, prints the expected Android/ABI
contract, preserves the archive, and stages a new disk without overwriting the
current one. With `DRY_RUN=1`, assert the boot command remains
`qemu-system-aarch64 -accel tcg ... -cpu max`, never KVM/x86/native-bridge.

**Step 2: Run tests to verify they fail**

Run: `bash tests/test_multilib_lab.sh provision`
Expected: FAIL because provisioning is pinned to the arm64-only release.

**Step 3: Implement artifact and dry-run handling**

Require `LINEAGE_MULTILIB_ZIP` or discover the newest builder output. Validate
the filename and archive layout before conversion. Use a staging raw disk and
atomic rename. Keep the existing vendor-boot and property patches, but make each
patch assert its expected source bytes. Add deterministic dry-run output to both
scripts.

**Step 4: Run provisioning and static tests**

Run: `bash tests/test_multilib_lab.sh provision`
Expected: PASS.

Run: `bash -n avd/lab avd/*.sh && shellcheck -S warning avd/lab avd/*.sh`
Expected: PASS.

**Step 5: Commit**

```bash
git add avd/provision.sh avd/boot-arm64.sh tests/test_multilib_lab.sh
git commit -m "feat: provision only the complete multilib ARM image"
```

### Task 6: Add real-bundle acceptance and operator documentation

**Files:**
- Create: `tests/accept_multilib_apps.sh`
- Modify: `README.md`
- Modify: `docs/arm64-testing.md`
- Modify: `tests/test_multilib_lab.sh`

**Step 1: Write failing acceptance-script contract tests**

Assert the script requires arm64 and arm32 bundle paths, records one boot ID,
uses the production installer, launches both packages, and validates:

```text
[accept] PASS package=com.example.arm64app abi=arm64-v8a exe=/system/bin/app_process64
[accept] PASS package=com.example.arm32app abi=armeabi-v7a exe=/system/bin/app_process32
[accept] PASS: both architectures launched during the same guest boot
```

It must reject `INSTALL_FAILED_NO_MATCHING_ABIS`, `UnsatisfiedLinkError`,
`CANNOT LINK EXECUTABLE`, wrong `primaryCpuAbi`, missing PID, or a changed boot
ID.

**Step 2: Run the test to verify it fails**

Run: `bash tests/test_multilib_lab.sh acceptance`
Expected: FAIL because the acceptance script does not exist.

**Step 3: Implement the script and docs**

Implement explicit `--arm64` and `--arm32` arguments plus optional serial.
Update docs to call the backend TCG-translated ARM, list exact build/provision
commands, explain source manifest/checksum artifacts, and distinguish guest ABI
support from 32-bit declaw mempatch support.

**Step 4: Run the complete deterministic suite**

Run: `bash tests/test_multilib_lab.sh`
Expected: PASS.

Run: `bash -n avd/lab avd/*.sh tests/*.sh`
Expected: PASS.

Run: `shellcheck -S warning avd/lab avd/*.sh tests/*.sh`
Expected: PASS.

Run: `git diff --check`
Expected: no output.

**Step 5: Commit**

```bash
git add tests/accept_multilib_apps.sh tests/test_multilib_lab.sh README.md docs/arm64-testing.md
git commit -m "docs: make dual-ABI acceptance reproducible"
```

### Task 7: Build, boot, and prove both production APKMs

**Files:**
- Generated outside git: Lineage source checkout, UTM ZIP, raw disk, proof log

**Step 1: Build the clean multilib artifact**

Run: `BUILD_ROOT=$HOME/Android/lineage-multilib-build ./avd/build-lineage-multilib.sh`
Expected: signed `virtio_arm64` UTM ZIP plus manifest and SHA-256 files; no
`arm64only` artifact.

**Step 2: Provision without replacing the working backup**

Run: `LINEAGE_MULTILIB_ZIP=<dist/UTM-VM-...-virtio_arm64.zip> LINEAGE_DIR=$HOME/Android/lineage-multilib ./avd/provision.sh`
Expected: patched `vda.raw` and preserved source archive.

**Step 3: Boot and run the live ABI gate**

Run: `LINEAGE_DIR=$HOME/Android/lineage-multilib ./avd/lab qemu up`

Run: `./avd/lab qemu check`
Expected: PASS with `zygote64_32`, both ABI lists, both runtimes, root, permissive
SELinux, Android 16/API 36, and `CONFIG_COMPAT=y`.

**Step 4: Run both real bundles in one boot**

Run: `tests/accept_multilib_apps.sh --arm64 <arm64-app.apkm> --arm32 <arm32-app.apkm>`
Expected: the arm64 app launches through `app_process64`, the arm32 app through
`app_process32`, with the same boot ID and no ABI/linker errors.

**Step 5: Run existing qemu regressions and record proof**

Run root/status/UI/capture smoke tests and one existing ARM64 mempatch flow.
Expected: existing ARM64 behavior remains intact. Save the exact commands,
artifact checksums, build manifest, and output in the release handoff.
