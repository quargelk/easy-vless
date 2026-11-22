#!/usr/bin/env bash
set -euo pipefail

# The OpenWrt SDK supplies package metadata, not the Go compiler.
version=1.14.4-lx.35
commit=f1bac271853eaf13398ce1030c948aebc3aed2e1
toolchain=go1.26.10
tags=with_quic,with_dhcp,with_utls,with_clash_api,with_xhttp,badlinkname,tfogo_checklinkname0

arch=${1:?usage: build-core.sh OPENWRT_ARCH OUTPUT}
output=${2:?usage: build-core.sh OPENWRT_ARCH OUTPUT}
case "$arch" in
	aarch64_*) goarch=arm64 ;;
	x86_64) goarch=amd64 ;;
	*) echo "No validated sing-box-lx build mapping for $arch" >&2; exit 2 ;;
esac
mkdir -p "$(dirname "$output")"
output="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git -c advice.detachedHead=false clone --depth 1 --branch "v$version" \
	https://github.com/Leadaxe/sing-box-lx "$work/source"
cd "$work/source"
test "$(git rev-parse HEAD)" = "$commit"
git submodule update --init --depth 1 submodules/gvisor submodules/sing-tun \
	submodules/utls submodules/wireguard-go

export GOOS=linux GOARCH="$goarch" CGO_ENABLED=0 GOTOOLCHAIN="$toolchain"
export GOAMD64=v1 GOARM64=v8.0
go build -mod=readonly -buildvcs=false -trimpath -tags "$tags" \
	-ldflags "-X github.com/sagernet/sing-box/constant.Version=$version -checklinkname=0 -s -w -buildid=" \
	-o "$output" ./cmd/sing-box
