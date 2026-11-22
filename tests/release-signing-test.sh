#!/bin/sh
# End-to-end signing test with a disposable key. Never use this key for release.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APK_TOOL=${1:?usage: release-signing-test.sh /path/to/openwrt-25.12-apk-tool}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/test-only.rsa" >/dev/null 2>&1
APK_TOOL="$APK_TOOL" sh "$ROOT/scripts/sign-release-apks.sh" \
	"$ROOT/dist/release-assets-1.3.0-r1" "$TMP/signed" "$TMP/test-only.rsa"
if env -u LD_PRELOAD "$APK_TOOL" verify "$TMP/signed/easy-vless-1.3.0-r1.apk" >"$TMP/no-trust.log" 2>&1; then
	echo "a clean trust store unexpectedly accepted the disposable signature" >&2
	exit 1
fi
grep -q 'UNTRUSTED signature' "$TMP/no-trust.log"
echo "clean trust store rejects the signature as expected"
