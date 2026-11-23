#!/bin/sh
# Flatten four verified bundles into unique assets for one GitHub Release.
set -eu
ROOT=${1:-dist/sing-box-lx-integration}
OUT=${2:-dist/release-assets-v1.3.0-rc.1-staged}
CORE_SOURCE=${3:-}
SRC=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$ROOT" && pwd)
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo "output directory already exists: $OUT" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")"
OUT=$(cd "$(dirname "$OUT")" && pwd -P)/$(basename "$OUT")
case "$OUT/" in "$ROOT"/*) echo "output must be outside input bundle tree" >&2; exit 2 ;; esac
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 2; }
tmp=$(mktemp -d "$(dirname "$OUT")/.prepare-release-assets.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
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
cp "$SRC/docs/INSTALL-1.3.0-RC.md" "$tmp/INSTALL-RC.md"
cp "$SRC/docs/RELEASE-NOTES-1.3.0-RC1.md" "$tmp/RELEASE-NOTES.md"
cp "$SRC/docs/THIRD-PARTY-RC.md" "$tmp/THIRD-PARTY.md"
if [ -n "$CORE_SOURCE" ]; then
	cp "$CORE_SOURCE" "$tmp/sing-box-lx-1.14.4-lx.35-source.tar.gz"
fi
(cd "$tmp" && sha256sum * > SHA256SUMS && sha256sum -c SHA256SUMS >/dev/null)
mv -T --no-clobber "$tmp" "$OUT"
[ ! -e "$tmp" ] || { echo "output directory appeared during preparation" >&2; exit 2; }
printf 'Staged assets: %s\n' "$OUT"
