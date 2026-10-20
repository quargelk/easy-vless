#!/bin/bash
# Easy VLESS - build the packages with an official OpenWrt SDK (local builds
# and CI). The SDK decides the package format: the 24.10 SDK writes .ipk
# (opkg), the 25.12 SDK writes .apk (apk v3). The packages themselves are
# architecture independent (PKGARCH:=all), so one SDK target is enough.
#
#   bash scripts/sdk-build.sh [--feeds] <sdk dir> <output dir>
#
#   --feeds   set up the official feeds of the SDK first (packages, luci) and
#             install the package definitions the Makefile depends on;
#             without it the SDK must already be prepared (CI does this
#             itself, with the geoview feed added).
#
# The source tree is copied into <sdk>/package/easy-vless (files known to
# git: tracked and untracked, not ignored). Text files are copied with LF line
# endings (a checkout on a Windows/NTFS file system may have CRLF), except the
# files .gitattributes marks "-text" (byte-for-byte resources).
# The five packages are built with the SDK's own package.mk / ipkg-build /
# apk mkpkg (make -C package/easy-vless ... compile: no rebuild of the
# dependencies) and copied to <output dir>. Nothing is downloaded except the
# feeds with --feeds.

set -euo pipefail
FEEDS=0
[ "${1:-}" = "--feeds" ] && { FEEDS=1; shift; }
SDK="$(cd "${1:?usage: $0 [--feeds] <sdk dir> <output dir>}" && pwd)"
OUT="${2:?usage: $0 [--feeds] <sdk dir> <output dir>}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
PKGS="easy-vless easy-vless-sing-box easy-vless-xray easy-vless-geodata luci-app-easy-vless"

[ -x "$SDK/scripts/feeds" ] && [ -f "$SDK/include/package.mk" ] || { echo "not an OpenWrt SDK: $SDK" >&2; exit 2; }

if [ "$FEEDS" = 1 ]; then
	(cd "$SDK" && ./scripts/feeds update packages luci \
		&& ./scripts/feeds install -p packages coreutils curl v2ray-geoip v2ray-geosite lyaml sing-box xray-core \
		&& ./scripts/feeds install -p luci luci-base luci-compat luci-lib-jsonc)
fi

# ---- source tree
DST="$SDK/package/easy-vless"
case "$DST" in */package/easy-vless) rm -rf "${DST:?}" ;; esac
mkdir -p "$DST"
cd "$SRC"
git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do
	case "$f" in .github/*|prototype/*|dist/*|docs/images/*) continue ;; esac
	[ -f "$f" ] || continue
	mkdir -p "$DST/$(dirname "$f")"
	if [ "$(git check-attr text -- "$f" | sed 's/.*: //')" = "unset" ] || ! grep -Iq . "$f"; then
		cp -p "$f" "$DST/$f"
	else
		tr -d '\r' < "$f" > "$DST/$f"
	fi
done
# shell scripts keep their executable bit (NTFS checkouts may lose it; the
# Makefile installs with INSTALL_BIN anyway)
find "$DST" -name '*.sh' -exec chmod +x {} +

# ---- build
cd "$SDK"
for p in $PKGS; do
	grep -q "^CONFIG_PACKAGE_${p}=" .config 2>/dev/null || echo "CONFIG_PACKAGE_${p}=m" >> .config
done
make defconfig >/dev/null
find bin -name '*easy-vless*' -type f -delete 2>/dev/null || true
make -C package/easy-vless TOPDIR="$SDK" clean compile V=s

# ---- collect
mkdir -p "$OUT"
v="$(sed -n 's/^PKG_VERSION:=//p' "$DST/Makefile")-r$(sed -n 's/^PKG_RELEASE:=//p' "$DST/Makefile")"
n=0
for p in $PKGS; do
	f="$(find bin -type f \( -name "${p}_${v}_all.ipk" -o -name "${p}-${v}.apk" \) | head -n1)"
	[ -n "$f" ] || { echo "package $p $v was not built" >&2; exit 1; }
	cp "$f" "$OUT/"
	echo "built: $OUT/$(basename "$f")"
	n=$((n + 1))
done
echo "$n packages, version $v, SDK $(sed -n 's/^CONFIG_VERSION_NUMBER="\(.*\)"$/\1/p' .config 2>/dev/null || true) $(grep -o '^CONFIG_TARGET_BOARD="[^"]*"' .config | cut -d'"' -f2)"
