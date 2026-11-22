#!/bin/sh
# Sign a prepared release set without rebuilding packages. Caller supplies a
# production private key; only its public key is copied into release assets.
set -eu
SRC=${1:?usage: sign-release-apks.sh ASSET_DIR OUTPUT_DIR PRIVATE_KEY}
OUT=${2:?usage: sign-release-apks.sh ASSET_DIR OUTPUT_DIR PRIVATE_KEY}
KEY=${3:?usage: sign-release-apks.sh ASSET_DIR OUTPUT_DIR PRIVATE_KEY}
APK_TOOL=${APK_TOOL:-apk}
OPENSSL=${OPENSSL:-openssl}
SRC=$(CDPATH= cd -- "$SRC" && pwd)
KEY=$(CDPATH= cd -- "$(dirname "$KEY")" && pwd)/$(basename "$KEY")
[ -f "$KEY" ] || { echo "private signing key not found" >&2; exit 2; }
[ -x "$APK_TOOL" ] || command -v "$APK_TOOL" >/dev/null 2>&1 || { echo "apk-tools executable not found" >&2; exit 2; }
command -v "$OPENSSL" >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 2; }
[ -f "$SRC/SHA256SUMS" ] || { echo "input SHA256SUMS is missing" >&2; exit 1; }
(cd "$SRC" && sha256sum -c SHA256SUMS >/dev/null) || { echo "input assets checksum failed" >&2; exit 1; }
[ ! -e "$OUT" ] || { echo "output directory must not already exist" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"
tmp=$(mktemp -d "$(dirname "$OUT")/.release-sign.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cp "$SRC"/* "$tmp/"
count=0
for f in "$tmp"/*.apk; do
	[ -f "$f" ] || continue
	"$APK_TOOL" adbsign --allow-untrusted --sign-key "$KEY" "$f" >/dev/null
	count=$((count + 1))
done
[ "$count" -gt 0 ] || { echo "no APK assets found" >&2; exit 1; }
mkdir -p "$tmp/verify-root/etc/apk/keys"
"$OPENSSL" pkey -in "$KEY" -pubout -out "$tmp/easy-vless-release.pem" 2>/dev/null
cp "$tmp/easy-vless-release.pem" "$tmp/verify-root/etc/apk/keys/"
for f in "$tmp"/*.apk; do
	"$APK_TOOL" --root "$tmp/verify-root" verify "$f" >/dev/null
done
rm -rf "$tmp/verify-root"
(cd "$tmp" && sha256sum ./*.apk ./*.ipk ./install.sh ./easy-vless-release.pem \
	| sed 's#  \./#  #' | sort -k2 > SHA256SUMS)
(cd "$tmp" && sha256sum -c SHA256SUMS >/dev/null)
mv "$tmp" "$OUT"
trap - EXIT HUP INT TERM
echo "Signed $count APK assets and verified them with an isolated trust root."
echo "Public key: $OUT/easy-vless-release.pem"
echo "Install this public key into /etc/apk/keys through a separately trusted channel before using the APK assets."
