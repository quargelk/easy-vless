#!/usr/bin/env bash
# Produce the corresponding source archive without rebuilding the core.
set -euo pipefail
export LC_ALL=C
umask 022
root=$(cd "$(dirname "$0")/.." && pwd)
source_dir=$(cd "${1:?usage: prepare-core-source.sh CORE_CHECKOUT OUTPUT_ARCHIVE}" && pwd)
out=$(realpath -m "${2:?missing output archive}")
prefix=sing-box-lx-1.14.4-lx.35
revision=f1bac271853eaf13398ce1030c948aebc3aed2e1
test "$(git -C "$source_dir" rev-parse HEAD)" = "$revision"
test ! -e "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/$prefix"
git -C "$source_dir" archive HEAD | tar -xf - -C "$work/$prefix"
for sub in gvisor sing-tun utls wireguard-go; do
	path="submodules/$sub"
	pin=$(git -C "$source_dir" rev-parse "HEAD:$path")
	test "$(git -C "$source_dir/$path" rev-parse HEAD)" = "$pin"
	# The pinned submodule archives exclude Git config and working-tree files.
	mkdir -p "$work/$prefix/$path"
	git -C "$source_dir/$path" archive "$pin" | tar -xf - -C "$work/$prefix/$path"
done
cp "$root/scripts/build-core.sh" "$work/$prefix/easy-vless-build-core.sh"
cp "$root/LICENSE" "$work/$prefix/GPL-3.0.txt"
(
	cd "$work/$prefix"
	export GOOS=linux CGO_ENABLED=0 GOTOOLCHAIN=go1.26.10 GOAMD64=v1 GOARM64=v8.0
	go mod vendor
	tags=$(sed -n 's/^tags=//p' easy-vless-build-core.sh)
	for arch in amd64 arm64; do
		GOARCH="$arch" go list -deps -buildvcs=false -mod=vendor -tags "$tags" ./cmd/sing-box > "$work/$arch.deps"
		if grep -q '^github.com/sagernet/cronet-go/lib' "$work/$arch.deps"; then
			echo "the RC unexpectedly requires prebuilt Cronet libraries" >&2
			exit 1
		fi
	done
	# Other build profiles use these prebuilt libraries. Neither RC ABI does.
	rm -rf vendor/github.com/sagernet/cronet-go/lib
	for arch in amd64 arm64; do
		GOARCH="$arch" go list -deps -buildvcs=false -mod=vendor -tags "$tags" ./cmd/sing-box | cmp "$work/$arch.deps" -
	done
)
epoch=$(git -C "$source_dir" show -s --format=%ct HEAD)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
	-C "$work" -cf - "$prefix" | gzip -n -1 > "$work/$prefix.tar.gz"
mv -T --no-clobber "$work/$prefix.tar.gz" "$out"
test ! -e "$work/$prefix.tar.gz"
