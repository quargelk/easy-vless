#!/bin/sh
# Flatten four verified bundles into unique assets for one GitHub Release.
set -eu
ROOT=${1:-dist/sing-box-lx-integration}
OUT=${2:-dist/release-assets-1.3.0-r1}
SRC=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$ROOT" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
case "$OUT/" in "$ROOT"/*) echo "output must be outside input bundle tree" >&2; exit 2 ;; esac
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 2; }
tmp="$OUT/.prepare-release-assets.$$"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp"
for channel in ipk-x86_64 ipk-aarch64_cortex-a53 apk-x86_64 apk-aarch64_cortex-a53; do
	dir="$ROOT/$channel"
	[ -d "$dir" ] || { echo "missing bundle: $channel" >&2; exit 1; }
	(cd "$dir" && sha256sum -c SHA256SUMS >/dev/null) || { echo "bundle checksum failed: $channel" >&2; exit 1; }
	for f in "$dir"/*.ipk "$dir"/*.apk; do
		[ -f "$f" ] || continue
		name=${f##*/}
		if [ -e "$tmp/$name" ]; then
			cmp -s "$f" "$tmp/$name" || { echo "asset name collision with different content: $name" >&2; exit 1; }
		else
			cp "$f" "$tmp/$name"
		fi
	done
done
cp "$SRC/scripts/install.sh" "$tmp/install.sh"
(cd "$tmp" && sha256sum ./*.apk ./*.ipk ./install.sh | sed 's#  \./#  #' | sort -k2 > SHA256SUMS)
(cd "$tmp" && sha256sum -c SHA256SUMS >/dev/null)
rm -f "$OUT"/*.apk "$OUT"/*.ipk "$OUT"/install.sh "$OUT"/SHA256SUMS
cp "$tmp"/* "$OUT/"
echo "Release assets prepared in $OUT"
echo "Assets: $(find "$OUT" -maxdepth 1 -type f | wc -l | tr -d ' ') (including SHA256SUMS)"
echo "Verify with: (cd '$OUT' && sha256sum -c SHA256SUMS)"
