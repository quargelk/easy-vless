#!/bin/sh
# Finalize a flat release bundle on the signing workstation.
set -eu
umask 077
export LC_ALL=C
SRC=${1:?usage: sign-release-apks.sh ASSET_DIR NEW_OUTPUT_DIR PRIVATE_KEY}
OUT=${2:?missing output directory}
KEY=${3:?missing private key}
APK_TOOL=${APK_TOOL:-apk}
OPENSSL=${OPENSSL:-openssl}
SRC=$(CDPATH= cd -- "$SRC" && pwd -P)
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
[ -f "$KEY" ] && [ ! -L "$KEY" ] || { echo "expected a private key file, not a symlink" >&2; exit 2; }
KEY=$(CDPATH= cd -- "$(dirname "$KEY")" && pwd -P)/$(basename "$KEY")
case "$KEY" in "$ROOT"/*|"$SRC"/*) echo "keep the private key outside the source and asset trees" >&2; exit 2 ;; esac
case "$(stat -c '%u:%a' "$KEY")" in
	"$(id -u):600"|"$(id -u):400") ;;
	*) echo "private key must belong to the signer with mode 0600 or 0400" >&2; exit 2 ;;
esac
[ -x "$APK_TOOL" ] || command -v "$APK_TOOL" >/dev/null
command -v "$OPENSSL" >/dev/null
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo "output directory already exists" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"
tmp=$(mktemp -d "$(dirname "$OUT")/.release-sign.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

# Copy exactly the expected assets, with no links or unlisted files.
{
	for p in easy-vless easy-vless-sing-box easy-vless-xray easy-vless-geodata luci-app-easy-vless; do
		printf '%s\n' "$p-1.3.0-r1.apk" "${p}_1.3.0-r1_all.ipk"
	done
	for arch in aarch64_cortex-a53 x86_64; do
		printf '%s\n' "sing-box-lx-1.14.4_p35-r1-$arch.apk" "sing-box-lx_1.14.4_p35-r1_$arch.ipk"
	done
	printf '%s\n' install.sh INSTALL-RC.md RELEASE-NOTES.md THIRD-PARTY.md sing-box-lx-1.14.4-lx.35-source.tar.gz
} | sort > "$tmp/expected"
awk 'NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || $2 !~ /^[A-Za-z0-9_.-]+$/ { exit 1 } { print $2 }' \
	"$SRC/SHA256SUMS" > "$tmp/names"
sort "$tmp/names" > "$tmp/actual"
cmp -s "$tmp/expected" "$tmp/actual" || { echo "unexpected or missing release asset" >&2; exit 1; }
while IFS= read -r file; do
	[ -s "$SRC/$file" ] && [ ! -L "$SRC/$file" ] || { echo "invalid asset: $file" >&2; exit 1; }
	cp "$SRC/$file" "$tmp/$file"
done < "$tmp/expected"
install -m 0644 "$SRC/SHA256SUMS" "$tmp/SHA256SUMS"
(cd "$tmp" && sha256sum -c SHA256SUMS >/dev/null)

"$OPENSSL" pkey -in "$KEY" -pubout -out "$tmp/easy-vless-release.pem"
mkdir -p "$tmp/verify-root/etc/apk/keys"
cp "$tmp/easy-vless-release.pem" "$tmp/verify-root/etc/apk/keys/"
for f in "$tmp"/*.apk; do
	# adbsign must accept the unsigned SDK input. Verification and installation
	# use the ordinary trust rules.
	"$APK_TOOL" adbsign --allow-untrusted --reset-signatures --sign-key "$KEY" "$f"
	"$APK_TOOL" --root "$tmp/verify-root" verify "$f"
done

(
	cd "$tmp"
	{ cat expected; echo easy-vless-release.pem; } | sort | while IFS= read -r file; do
		sha256sum "$file" || exit 1
	done > SHA256SUMS
	sha256sum -c SHA256SUMS >/dev/null
	"$OPENSSL" dgst -sha256 -sign "$KEY" -out SHA256SUMS.sig SHA256SUMS
	"$OPENSSL" dgst -sha256 -verify easy-vless-release.pem -signature SHA256SUMS.sig SHA256SUMS
)
# Compute the identity before publishing the completed output directory.
"$OPENSSL" pkey -pubin -in "$tmp/easy-vless-release.pem" -outform DER -out "$tmp/key.der"
fingerprint=$(sha256sum "$tmp/key.der")
rm -rf "$tmp/verify-root" "$tmp/expected" "$tmp/actual" "$tmp/names" "$tmp/key.der"
# -T keeps concurrent signing attempts from nesting their result in OUT.
chmod 0644 "$tmp"/*
chmod 0755 "$tmp/install.sh"
mv -T --no-clobber "$tmp" "$OUT"
[ ! -e "$tmp" ] || { echo "output directory appeared during signing" >&2; exit 2; }
printf 'Public key SHA-256 (DER SubjectPublicKeyInfo): %s\n' "${fingerprint%% *}"
printf 'Signed bundle: %s\n' "$OUT"
