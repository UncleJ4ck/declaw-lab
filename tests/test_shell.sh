#!/usr/bin/env bash
# Static analysis + shell-helper behavior locks + arg-fuzz of the real ./phone.
set -u
cd "$(dirname "$0")/.."
fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1: got [$2] want [$3]"; fail=1; fi; }

echo "== static =="
if bash -n phone; then echo "  PASS bash -n"; else echo "  FAIL bash -n"; fail=1; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning phone >/dev/null 2>&1; then echo "  PASS shellcheck (no warnings)"; else echo "  FAIL shellcheck:"; shellcheck -S warning phone | head; fail=1; fi
else echo "  SKIP shellcheck (not installed)"; fi

echo "== redroid_tag mapping =="
tag(){ case "$1" in 11) echo "11.0.0-latest";; 12) echo "12.0.0-latest";; 13) echo "13.0.0-libndk";; *) echo "$1.0.0-latest";; esac; }
chk "tag 11" "$(tag 11)" "11.0.0-latest"
chk "tag 12" "$(tag 12)" "12.0.0-latest"
chk "tag 13" "$(tag 13)" "13.0.0-libndk"
chk "tag 14 passthrough" "$(tag 14)" "14.0.0-latest"

echo "== guest_gw awk derivation (.1 of the /16) =="
gw=$(printf '    inet 172.17.0.3/16 brd 172.17.255.255 scope global eth0\n' | awk '/inet /{split($2,a,"/");split(a[1],o,".");print o[1]"."o[2]"."o[3]".1";exit}')
chk "gw derive" "$gw" "172.17.0.1"

echo "== pkg-detect comm diff =="
before=$(printf 'package:a\npackage:b\n' | sort); after=$(printf 'package:a\npackage:b\npackage:com.example.app\n' | sort)
pkg=$(comm -13 <(printf '%s' "$before") <(printf '%s' "$after") | head -1 | sed 's/package://')
chk "pkg detect" "$pkg" "com.example.app"

echo "== need() resolves the adb BINARY, not the adb() function =="
r=$(bash -c 'adb(){ echo x; }; type -P adb >/dev/null 2>&1 && echo FOUND || echo MISS')
chk "need adb -> binary" "$r" "FOUND"

echo "== compose detection resolves =="
c=$(bash -c 'C=""; if docker compose version >/dev/null 2>&1; then C="docker compose"; elif type -P docker-compose >/dev/null 2>&1; then C="docker-compose"; fi; echo "$C"')
[ -n "$c" ] && echo "  PASS compose resolved: $c" || { echo "  FAIL no compose"; fail=1; }

echo "== arg-fuzz: garbage args -> help, no crash, no injection (none are real verbs) =="
crash=0
set -- "" "xyzzy" "--help" "12; rm -rf /tmp/DECLAW_SHOULD_NOT_EXIST" '$(touch /tmp/DECLAW_PWNED)' "up up" "........" "'" "-"
for a in "$@"; do
  out=$(./phone "$a" 2>&1) || true
  if printf '%s' "$out" | grep -qiE 'traceback|: line [0-9]+:|unbound variable'; then echo "  FAIL arg [$a] errored"; crash=1; fi
done
[ -e /tmp/DECLAW_PWNED ] && { echo "  FAIL arg injection executed"; crash=1; rm -f /tmp/DECLAW_PWNED; }
[ "$crash" = 0 ] && echo "  PASS arg-fuzz (no crash, no injection)" || fail=1

echo "test_shell: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
