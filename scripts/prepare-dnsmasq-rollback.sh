#!/bin/sh
# Seal an archived dnsmasq APK against an authenticated OpenWrt ROM database.
# Run on the signing workstation, with a ROM database obtained through trusted
# SSH or extracted from a verified copy of the exact OpenWrt firmware.
set -eu
umask 077
APK_TOOL=${APK_TOOL:-apk}
original=${1:?usage: prepare-dnsmasq-rollback.sh APK ROM_INSTALLED NEW_DIR PRIVATE_KEY}
rom=${2:?missing OpenWrt ROM package database}
out=${3:?missing output directory}
key=${4:?missing private key}
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
[ -f "$key" ] && [ ! -L "$key" ]
key=$(CDPATH= cd -- "$(dirname "$key")" && pwd -P)/$(basename "$key")
case "$key" in "$root"/*) echo "keep the private key outside the source tree" >&2; exit 2 ;; esac
case "$(stat -c '%u:%a' "$key")" in
	"$(id -u):600"|"$(id -u):400") ;;
	*) echo "private key must belong to the signer with mode 0600 or 0400" >&2; exit 2 ;;
esac
[ ! -e "$out" ] && [ ! -L "$out" ]
mkdir -p "$(dirname "$out")"
tmp=$(mktemp -d "$(dirname "$out")/.dnsmasq-sign.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
cp "$original" "$tmp/archive.apk"
# Decode the v3 container without relying on its self-declared unique ID.
"$APK_TOOL" adbsign --allow-untrusted --compression none "$tmp/archive.apk"
version=$(python3 - "$rom" "$tmp/archive.apk" <<'PY'
import base64
import hashlib
from pathlib import Path
import re
import struct
import sys

records = [record.splitlines() for record in Path(sys.argv[1]).read_text().split("\n\n")]
dnsmasq, = [record for record in records if "P:dnsmasq" in record]
version, = [line[2:] for line in dnsmasq if line.startswith("V:")]
identity, = [line[2:] for line in dnsmasq if line.startswith("C:")]
if not re.fullmatch(r"[0-9][A-Za-z0-9.+_-]*", version) or not identity.startswith("Q1"):
    sys.exit("Unrecognized OpenWrt ROM package record")
expected = base64.b64decode(identity[2:], validate=True)
archive = Path(sys.argv[2]).read_bytes()
length, = struct.unpack_from("<I", archive, 8)
if archive[:8] != b"ADB.pckg" or not 4 <= length < min(1 << 30, len(archive) - 8):
    sys.exit("Invalid APK v3 package block")
# OpenWrt 25.12 stores the first 20 bytes of the APK v3 SHA-256
# identity in the installed database. The ADB block binds the file hashes.
if len(expected) != 20 or hashlib.sha256(archive[12:8 + length]).digest()[:20] != expected:
    sys.exit("Archived APK does not match the trusted ROM package identity")
print(version)
PY
)
apk="$tmp/dnsmasq-$version.apk"
arch=$("$APK_TOOL" adbdump "$tmp/archive.apk" | sed -n "s/^  arch: //p" | head -n1)
case "$arch" in aarch64_cortex-a53|x86_64) ;; *) echo "unsupported dnsmasq ABI" >&2; exit 1 ;; esac
mv "$tmp/archive.apk" "$apk"
mkdir -p "$tmp/trust/etc/apk/keys"
openssl pkey -in "$key" -pubout -out "$tmp/trust/etc/apk/keys/easy-vless-release.pem"
"$APK_TOOL" adbsign --allow-untrusted --reset-signatures --sign-key "$key" "$apk"
"$APK_TOOL" --root "$tmp/trust" verify "$apk"
"$APK_TOOL" --root "$tmp/trust" mkndx --sign-key "$key" --output "$tmp/packages.adb" "$apk"
"$APK_TOOL" --root "$tmp/trust" verify "$tmp/packages.adb"
mkdir "$tmp/fetched"
"$APK_TOOL" --root "$tmp/trust" --arch "$arch" --network=no --repositories-file /dev/null \
	--repository "$tmp/packages.adb" fetch -o "$tmp/fetched" dnsmasq
cmp "$apk" "$tmp/fetched/${apk##*/}"
rm -rf "$tmp/trust" "$tmp/fetched"
mv -T --no-clobber "$tmp" "$out"
[ ! -e "$tmp" ]
printf 'Verified offline recovery: %s\n' "$out"
