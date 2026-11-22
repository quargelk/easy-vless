#!/usr/bin/env bash
set -euo pipefail

file=${1:?usage: core-package-check.sh PACKAGE OPENWRT_ARCH [APK_TOOL]}
arch=${2:?missing OpenWrt package architecture}
version=1.14.4_p35-r1
file="$(realpath "$file")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
case "$file" in
	*.ipk)
		tar -xzf "$file" -C "$work"
		tar -xOzf "$work/control.tar.gz" ./control > "$work/metadata"
		for line in 'Package: sing-box-lx' "Version: $version" "Architecture: $arch"; do
			grep -Fx "$line" "$work/metadata"
		done
		grep -E '^Depends: .*ca-bundle' "$work/metadata"
		tar -xzf "$work/data.tar.gz" -C "$work"
	;;
	*.apk)
		apk=${3:?missing SDK apk binary}
		"$apk" adbdump "$file" > "$work/metadata"
		for line in '  name: sing-box-lx' "  version: $version" "  arch: $arch" '    - ca-bundle'; do
			grep -Fx -- "$line" "$work/metadata"
		done
		# SDK output may be unsigned in CI. This only extracts the package.
		"$apk" extract --allow-untrusted --destination "$work" "$file"
	;;
	*) exit 2 ;;
esac
bin="$work/usr/bin/sing-box-lx"
test -x "$bin"
test ! -e "$work/usr/bin/sing-box"
case "$arch" in aarch64_*) machine=AArch64 ;; x86_64) machine='Advanced Micro Devices X86-64' ;; *) exit 2 ;; esac
readelf -h "$bin" | grep -F "$machine"
headers=$(readelf -l "$bin")
[[ "$headers" != *INTERP* ]]
go version -m "$bin" | grep -F 'CGO_ENABLED=0'
printf 'binary bytes=%s\n' "$(stat -c %s "$bin")"
sha256sum "$file" "$bin"
if [[ "$arch" == x86_64 ]]; then
	python3 "$(dirname "$0")/core-network.py" "$bin"
fi
