#!/usr/bin/env bash
# Install a CA into the RUNNING arm64 Android so mitmproxy can decrypt the clean
# (unpinned) baseline. Android 14+ moved the system trust store into the
# updatable conscrypt APEX (/apex/com.android.conscrypt/cacerts), so writing to
# /system/etc/security/cacerts no longer changes trust. The working technique
# (needs root): rebuild the cert dir in a tmpfs and bind-mount it over BOTH the
# apex store and the legacy path, then restart Zygote so apps re-read it.
#
# Usage: install-ca.sh [serial] [pem]   (defaults: localhost:5555, mitmproxy CA)
set -euo pipefail
SERIAL="${1:-localhost:5555}"
CERT="${2:-$HOME/.mitmproxy/mitmproxy-ca-cert.pem}"
A="adb -s $SERIAL"

[ -f "$CERT" ] || { echo "no CA at $CERT"; exit 1; }
hash=$(openssl x509 -inform PEM -subject_hash_old -in "$CERT" | head -1)
echo "[ca] $CERT  ->  ${hash}.0"
$A push "$CERT" "/data/local/tmp/${hash}.0"

$A shell su -c "sh -c '
set -e
H=${hash}
APEX=/apex/com.android.conscrypt/cacerts
LEG=/system/etc/security/cacerts
T=/data/local/tmp/cacerts_tmp
rm -rf \$T; mkdir -p \$T
# seed with whatever the live store currently trusts, then add ours
cp -f \$APEX/* \$T/ 2>/dev/null || cp -f \$LEG/* \$T/ 2>/dev/null || true
cp -f /data/local/tmp/\$H.0 \$T/
chmod 644 \$T/*
chcon u:object_r:system_security_cacerts_file:s0 \$T/* 2>/dev/null || true
# overlay both stores
mount -t tmpfs tmpfs \$APEX 2>/dev/null || true
cp -f \$T/* \$APEX/ 2>/dev/null || true
chcon u:object_r:system_security_cacerts_file:s0 \$APEX/* 2>/dev/null || true
mount -t tmpfs tmpfs \$LEG 2>/dev/null || true
cp -f \$T/* \$LEG/
chcon u:object_r:system_security_cacerts_file:s0 \$LEG/* 2>/dev/null || true
echo installed \$(ls \$APEX | wc -l) certs into apex store
'"
echo "[ca] restarting zygote so apps re-read the store"
$A shell su -c 'stop; start' || $A shell su -c 'setprop ctl.restart zygote' || true
echo "[ca] done"
