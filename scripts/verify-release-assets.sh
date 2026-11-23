#!/bin/sh
# Verify on a trusted workstation. stdout is the pin for install.sh.
set -eu
umask 077
dir=${1:?usage: verify-release-assets.sh SIGNED_ASSET_DIR TRUSTED_KEY_SHA256}
pin=${2:?missing trusted public-key fingerprint}
case "$pin" in *[!0-9a-f]*) exit 2 ;; esac
[ "${#pin}" = 64 ] || exit 2
cd "$dir"
der=$(mktemp)
trap 'rm -f "$der"' EXIT
trap 'exit 1' HUP INT TERM
openssl pkey -pubin -in easy-vless-release.pem -outform DER -out "$der"
got=$(sha256sum "$der")
[ "${got%% *}" = "$pin" ] || { echo "release public key fingerprint mismatch" >&2; exit 1; }
openssl dgst -sha256 -verify easy-vless-release.pem -signature SHA256SUMS.sig SHA256SUMS >&2
# Read only safe relative filenames. Reject duplicate manifest entries.
awk 'NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ ||
	$2 !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/ || seen[$2]++ { exit 1 }
	$2 == "easy-vless-release.pem" { key = 1 }
	$2 == "install.sh" { installer = 1 }
	END { if (!key || !installer) exit 1 }' SHA256SUMS
sha256sum -c --strict SHA256SUMS >&2
digest=$(sha256sum SHA256SUMS)
printf '%s\n' "${digest%% *}"
