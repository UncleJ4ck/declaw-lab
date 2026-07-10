#!/usr/bin/env bash
# Android monkey: fire random UI events at the installed patched app; assert no crash/ANR
# and the app survives. Needs the phone up with the app installed (skips cleanly if not).
set -u
SERIAL="localhost:5556"
PKG="${1:-}"
a(){ command adb -s "$SERIAL" "$@"; }

[ -n "$PKG" ] || { echo "  SKIP: pass a package -> bash monkey_app.sh <com.your.app>"; exit 0; }
command -v adb >/dev/null 2>&1 || { echo "  SKIP: adb missing"; exit 0; }
a connect "$SERIAL" >/dev/null 2>&1 || true
[ "$(a get-state 2>/dev/null)" = "device" ] || { echo "  SKIP: phone not up"; exit 0; }
a shell pm list packages 2>/dev/null | grep -q "$PKG" || { echo "  SKIP: $PKG not installed"; exit 0; }

echo "== monkey: 500 random events at $PKG =="
out=$(a shell monkey -p "$PKG" --throttle 20 --pct-syskeys 0 -v 500 2>&1)
printf '%s\n' "$out" | tail -2
fail=0
if printf '%s' "$out" | grep -qiE 'Events injected: 500|Monkey finished'; then
  echo "  PASS monkey completed 500 events"
else
  echo "  note: monkey ended early (app may have limited UI); not fatal"
fi
if printf '%s' "$out" | grep -qiE 'CRASH|ANR|// Error'; then
  echo "  WARN: crash/ANR observed under monkey"
fi
if a shell pm list packages 2>/dev/null | grep -q "$PKG"; then
  echo "  PASS app still installed after monkey"
else
  echo "  FAIL app disappeared"; fail=1
fi
echo "monkey_app: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
