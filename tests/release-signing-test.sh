#!/bin/sh
# End-to-end tooling test with a disposable key and the real staged assets.
set -eu
umask 077
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APK_TOOL=${1:?usage: release-signing-test.sh APK_HOST_TOOL STAGED_ASSETS}
ASSETS=${2:?missing staged assets directory}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' HUP INT TERM
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/test-only.rsa" 2>/dev/null
APK_TOOL="$APK_TOOL" sh "$ROOT/scripts/sign-release-apks.sh" "$ASSETS" "$TMP/signed" "$TMP/test-only.rsa"
pkg="$TMP/signed/easy-vless-1.3.0-r1.apk"
openssl pkey -pubin -in "$TMP/signed/easy-vless-release.pem" -outform DER -out "$TMP/key.der"
fp=$(sha256sum "$TMP/key.der")
check_bundle() { sh "$ROOT/scripts/verify-release-assets.sh" "$TMP/signed" "$1" >/dev/null 2>&1; }
check_bundle "${fp%% *}"
if check_bundle 0000000000000000000000000000000000000000000000000000000000000000; then
	echo "wrong release key fingerprint accepted" >&2
	exit 1
fi
printf '\n' >> "$TMP/signed/SHA256SUMS"
if check_bundle "${fp%% *}"; then echo "changed manifest accepted" >&2; exit 1; fi
echo "PASS signed manifest and pinned key; fingerprint and manifest tampering rejected"

mkdir -p "$TMP/empty/etc/apk/keys" "$TMP/trusted/etc/apk/keys"
cp "$TMP/signed/easy-vless-release.pem" "$TMP/trusted/etc/apk/keys/"
"$APK_TOOL" --root "$TMP/trusted" verify "$pkg"
reject() {
	if "$APK_TOOL" --root "$1" verify "$2" >"$TMP/reject.log" 2>&1; then
		echo "apk accepted $2 using $1" >&2
		exit 1
	fi
	grep -Ei "$3" "$TMP/reject.log"
}
reject "$TMP/empty" "$pkg" 'untrusted signature'
cp "$pkg" "$TMP/uncompressed.apk"
"$APK_TOOL" adbsign --allow-untrusted --reset-signatures --compression none --sign-key "$TMP/test-only.rsa" "$TMP/uncompressed.apk"
"$APK_TOOL" --root "$TMP/trusted" verify "$TMP/uncompressed.apk"
python3 - "$TMP" <<'PY'
from pathlib import Path
import struct
import sys

root = Path(sys.argv[1])
data = (root / 'uncompressed.apk').read_bytes()
assert data[:4] == b'ADB.'
blocks = {}
offset = 8
while offset < len(data):
    header, = struct.unpack_from('<I', data, offset)
    kind, size = header >> 30, header & 0x3fffffff
    assert kind < 3 and size >= 4 and offset + size <= len(data)
    blocks.setdefault(kind, offset + size - 1)
    offset += (size + 7) & ~7
for kind, name in ((1, 'bad-signature'), (2, 'bad-payload')):
    modified = bytearray(data)
    modified[blocks[kind]] ^= 1
    (root / (name + '.apk')).write_bytes(modified)
PY
reject "$TMP/trusted" "$TMP/bad-signature.apk" 'untrusted signature|signature verification'
reject "$TMP/trusted" "$TMP/bad-payload.apk" 'integrity|checksum'
echo "PASS apk rejects an unknown key, damaged signature and damaged package content"
