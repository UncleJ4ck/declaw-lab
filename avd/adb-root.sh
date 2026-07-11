#!/usr/bin/env bash
# Connect to the arm64 rig and get a root adb shell. The disk (vda.raw) is already
# patched to ro.debuggable=1 + ro.adb.secure=0 (see boot-arm64.sh), so trade-in
# mode is off, no adb auth is needed, and the LineageOS root gate can be flipped:
# persist.sys.root_access=3 (bit 2 = ADB root) + restart adbd, then `adb root`.
# persist.sys.root_access is persistent, so on later boots of the same /data this
# is usually already set and a plain `adb root` is enough.
set -u
PORT="${ADB_PORT:-6555}"; D="localhost:$PORT"
adb connect "$D" >/dev/null 2>&1
for i in $(seq 1 40); do
  [ "$(adb -s "$D" get-state 2>/dev/null)" = "device" ] && \
    [ "$(timeout 8 adb -s "$D" shell echo OK 2>/dev/null | tr -d '\r')" = "OK" ] && break
  sleep 5; adb connect "$D" >/dev/null 2>&1
done
adb -s "$D" shell 'setprop persist.sys.root_access 3; setprop service.adb.root 1; setprop ctl.restart adbd' >/dev/null 2>&1
sleep 5; adb connect "$D" >/dev/null 2>&1
adb -s "$D" root >/dev/null 2>&1; sleep 4; adb connect "$D" >/dev/null 2>&1
id=$(adb -s "$D" shell id 2>&1 | tr -d '\r')
echo "$id"
echo "$id" | grep -q "uid=0" && echo "[root] ready on $D (aarch64, permissive)" || { echo "[root] FAILED"; exit 1; }
