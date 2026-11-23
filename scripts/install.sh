#!/bin/sh
# Easy VLESS installer for stable OpenWrt 24.x (24.10.x: opkg, .ipk) and
# stable OpenWrt 25.x (25.12.x: apk, .apk), fw4/nftables, x86_64 and
# aarch64_cortex-a53.
# https://github.com/quargelk/easy-vless
#
# A plain, readable shell script: download it, read it, then run it as root.
#   wget -O /tmp/install.sh https://github.com/quargelk/easy-vless/releases/download/v1.3.0-rc.1/install.sh
# See INSTALL-RC.md for verification and the required manifest digest.
#
# Package channel: chosen from the OpenWrt release in /etc/openwrt_release
# and the package manager that is actually present - both must agree:
#   OpenWrt 24.x (24.10.0 ...)  opkg  easy-vless_<version>_all.ipk ...
#   OpenWrt 25.x (25.12.0 ...)  apk   easy-vless-<version>.apk ...
# Any other release (older, newer, release candidate, snapshot) or a package
# manager that does not fit the release stops the installer before anything
# is changed. The package architecture of an apk system is the one in
# /etc/apk/arch (it must be DISTRIB_ARCH); "apk --print-arch" is only the CPU
# family apk was built for (aarch64, armv7, mips, ...).
#
# Application packages are architecture independent; sing-box-lx is built
# for the exact OpenWrt package architecture. Other dependencies come from
# official feeds. The old /usr/bin/sing-box remains owned by its package.
# Signed APKs use the router's trust store.
#
# Downloads always use HTTPS with certificate verification (never
# --no-check-certificate). Optional packages (easy-vless-xray,
# easy-vless-geodata) are never installed by this script.

set -u

EV_VERSION="1.3.0-r1"
EV_TAG="v1.3.0-rc.1"
EV_REPO="quargelk/easy-vless"
EV_BASE_URL="https://github.com/${EV_REPO}/releases/download/${EV_TAG}"
# Release date of this installer: a system clock before this date is certainly
# wrong, and TLS certificates cannot be verified with it.
EV_MIN_DATE="2026-11-22"
EV_PACKAGES="sing-box-lx easy-vless easy-vless-sing-box luci-app-easy-vless"
LX_PKG_VERSION="1.14.4_p35-r1"
LX_VERSION="1.14.4-lx.35"
# GitHub mirrors tried automatically when the default github.com base URL
# cannot be reached (some providers block the github.com network, 140.82.0.0/16,
# while the GitHub CDN that serves the assets stays reachable). Each entry is
# used as a prefix in front of the full github.com URL, e.g.
# https://ghproxy.net/https://github.com/<repo>/releases/download/<tag>/<file>.
# The fallback runs ONLY for the default base URL: --base-url and --local take
# precedence and disable it, and --no-mirror turns it off. The manifest
# digest is obtained independently of any mirror.
EV_MIRRORS="...".
EV_MIRRORS="${EV_MIRRORS:-https://ghproxy.net https://gh-proxy.com https://ghfast.top}"
# Supported OpenWrt major releases and the package manager each one uses
# by major and minor number. Firmware release candidates and snapshots
# require --force.
SUPPORTED_SERIES="24.10:opkg 25.12:apk"
SUPPORTED_RELEASE="24.10.x or 25.12.x"
OPKG_STATUS="/usr/lib/opkg/status"
# package architectures of apk (OpenWrt 25.12)
APK_ARCH_FILE="/etc/apk/arch"
APK_DISTFEEDS="/etc/apk/repositories.d/distfeeds.list"
# set by detect_channel: opkg or apk
PM=""

# System requirements.
# RAM: 256 MB installed. The kernel reports less as MemTotal (its own code
# and memory reserved for Wi-Fi offload/firmware: a 256 MB router shows about
# 225-250 MB), so a MemTotal of at least 200 MB is accepted as 256 MB; a
# 128 MB router shows about 120 MB and is refused.
MIN_RAM_MB=256
MIN_RAM_KB=204800
# Flash/storage: at least 128 MB in total (NAND/NOR chip or disk; "128 MB"
# media hold 128,000,000 bytes = 125000 KiB or more). The space actually
# needed is checked separately against the free space of the overlay.
MIN_STORAGE_MB=128
MIN_STORAGE_KB=125000
# Free space: worst-case installed size of every new package plus this
# reserve (opkg database and control files, configuration, subscription and
# resource data written at run time).
SPACE_RESERVE_KB=2048
# UBIFS (LZO) and JFFS2 (LZMA) compress every file. Measured on the sing-box
# binary (4 KiB blocks as UBIFS compresses them): 55 % of the uncompressed
# size with zlib-1, LZO a little more; the CI job "ubifs" verifies the value
# on a real UBIFS. Other filesystems (ext4, f2fs, tmpfs) are counted 1:1.
COMPRESSED_FS_PERCENT=75
# Test hook: hardware information (/proc/meminfo, /proc/mounts, /proc/mtd,
# /sys/class/mtd, /sys/class/ubi, /sys/block, kernel log in dmesg.txt) is read
# below this directory instead of / (tests/ci/sysroot/*: layouts of real
# devices that a container cannot have).
SYS="${EV_TEST_SYSROOT:-}"

OPT_CHECK=0
OPT_LOCAL=""
OPT_OFFLINE=0
OPT_MANIFEST_SHA256=""
OPT_ROLLBACK=""
OPT_DNS_ROLLBACK=""
OPT_NO_MIRROR=0
USER_BASE_URL=0
OPT_REPLACE_DNSMASQ=0
OPT_YES=0
OPT_NO_START=0
OPT_FORCE=0

WORKDIR=""
DNSMASQ_STAGE=""
EV_STAGE=""
EV_PREVIOUS_FILES=""
EV_LEGACY_APKS=""
EV_WAS_ENABLED=0
EV_ADDED=""
HTTPS_BROKEN=0
HTTPS_URL=""
HTTPS_ERR=""

say()  { echo "[easy-vless] $*"; }
warn() { echo "[easy-vless] WARNING: $*" >&2; }
die()  { echo "[easy-vless] ERROR: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Easy VLESS ${EV_TAG} (${EV_VERSION}) installer for stable OpenWrt 24.x (24.10.x: opkg,
.ipk) and stable OpenWrt 25.x (25.12.x: apk, .apk), fw4/nftables

Usage: sh install.sh [options]

  --check, --dry-run only run the checks (router, RAM, flash, time, HTTPS,
                     package manager and feeds, sing-box-lx, dnsmasq, release
                     files, free space); install and change nothing (files
                     are only downloaded to a temporary directory in /tmp)
  --local DIR        install the Easy VLESS packages of this router's channel
                     (.ipk for opkg, .apk for apk) and SHA256SUMS from DIR
                     instead of downloading them from GitHub
  --manifest-sha256 HEX
                     SHA-256 of the independently authenticated SHA256SUMS
                     (required for both IPK and APK)
  --offline         use --local and currently installed system dependencies
  --rollback-dir DIR use verified previous Easy VLESS packages from DIR
  --dnsmasq-rollback-dir DIR
                     use a previously saved official signed index and exact
                     installed dnsmasq package when the current feed changed
  --base-url URL     download the release files from URL (an https:// mirror
                     of ${EV_BASE_URL}); disables the automatic mirror fallback
  --no-mirror        do not fall back to a GitHub mirror when github.com cannot
                     be reached (fail with the plain connection error instead)
  --replace-dnsmasq  allow replacing dnsmasq with dnsmasq-full
  --yes, -y          answer "yes" to the dnsmasq question (implies
                     --replace-dnsmasq)
  --no-start         do not restart the service at the end
  --force            try an untested OpenWrt release if the package manager
                     and ABI match; feed and resource checks still apply
  -h, --help         show this help

Optional packages (easy-vless-xray, easy-vless-geodata) are never installed
by this script.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--check|--dry-run) OPT_CHECK=1 ;;
		--local) [ $# -ge 2 ] || die "--local needs a directory"; OPT_LOCAL="$2"; shift ;;
		--offline) OPT_OFFLINE=1 ;;
		--manifest-sha256) [ $# -ge 2 ] || die "--manifest-sha256 needs a digest"; OPT_MANIFEST_SHA256="$2"; shift ;;
		--dnsmasq-rollback-dir) [ $# -ge 2 ] || die "--dnsmasq-rollback-dir needs a directory"; OPT_DNS_ROLLBACK="$2"; shift ;;
		--rollback-dir) [ $# -ge 2 ] || die "--rollback-dir needs a directory"; OPT_ROLLBACK="$2"; shift ;;
		--base-url) [ $# -ge 2 ] || die "--base-url needs a URL"; EV_BASE_URL="${2%/}"; USER_BASE_URL=1; shift ;;
		--no-mirror) OPT_NO_MIRROR=1 ;;
		--replace-dnsmasq) OPT_REPLACE_DNSMASQ=1 ;;
		--yes|-y) OPT_YES=1; OPT_REPLACE_DNSMASQ=1 ;;
		--no-start) OPT_NO_START=1 ;;
		--force) OPT_FORCE=1 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1 (see --help)" ;;
	esac
	shift
done
case "$EV_BASE_URL" in
	https://?*) ;;
	*) die "--base-url must be an https:// URL (downloads are never made without TLS): $EV_BASE_URL" ;;
esac

[ "${#OPT_MANIFEST_SHA256}" = 64 ] || die "provide --manifest-sha256 from the verified release manifest (see INSTALL-RC.md)"
case "$OPT_MANIFEST_SHA256" in *[!0-9a-f]*) die "invalid --manifest-sha256 (expected 64 lowercase hex digits)" ;; esac
[ "$OPT_OFFLINE" = 0 ] || [ -n "$OPT_LOCAL" ] || die "--offline requires --local"
[ -z "$OPT_ROLLBACK" ] || OPT_ROLLBACK="$(cd "$OPT_ROLLBACK" && pwd)" || die "invalid rollback directory"
[ -z "$OPT_DNS_ROLLBACK" ] || OPT_DNS_ROLLBACK="$(cd "$OPT_DNS_ROLLBACK" && pwd)" || die "invalid dnsmasq rollback directory"

# ---------------------------------------------------------------- helpers

# pkg_field PACKAGE FIELD: a field of the package in the feed index (opkg
# field names: Version, Architecture, Depends; apk: the same value from
# "apk query", e.g. Architecture = "Arch")
pkg_field() {
	local f="$2"
	if [ "$PM" = "apk" ]; then
		[ "$f" = "Architecture" ] && f="Arch"
		apk query --available --fields "$(echo "$f" | tr 'A-Z' 'a-z')" "$1" 2>/dev/null | sed -n "s/^$f: //p" | head -n1
		return 0
	fi
	opkg info "$1" 2>/dev/null | sed -n "s/^$f: //p" | head -n1
}

# pkg_file PACKAGE: file name of an Easy VLESS package of this release in the
# channel of this router
pkg_version() {
	case "$1" in sing-box-lx) echo "$LX_PKG_VERSION" ;; *) echo "${2:-$EV_VERSION}" ;; esac
}

pkg_arch() {
	if [ "$1" = sing-box-lx ]; then echo "$DISTRIB_ARCH"
	elif [ "$PM" = apk ]; then echo noarch
	else echo all; fi
}

pkg_file() {
	local ver arch
	ver="$(pkg_version "$1" "${2:-}")"
	arch="$(pkg_arch "$1")"
	if [ "$PM" = apk ]; then
		if [ "$1" = sing-box-lx ]; then echo "$1-$ver-$arch.apk"; else echo "$1-$ver.apk"; fi
	else
		echo "${1}_${ver}_${arch}.ipk"
	fi
}

# apk_file_field FILE FIELD: a field of the package information of an .apk
# file (name, version, arch, installed-size, ...)
apk_file_field() { apk adbdump "$1" 2>/dev/null | sed -n "s/^  $2: //p" | head -n1; }

# feed_sha256 PACKAGE FILE: SHA256 of FILE from the (signature-checked) feed
# index, via "opkg info" or, when that does not print it, the downloaded lists
feed_sha256() {
	local sum l
	sum="$(pkg_field "$1" SHA256sum)"
	if [ -z "$sum" ]; then
		for l in "$WORKDIR/opkg-lists"/*; do
			[ -f "$l" ] || continue
			case "$l" in *.sig) continue ;; esac
			sum="$( { gzip -dc "$l" 2>/dev/null || cat "$l"; } | awk -v p="$1" -v f="$2" '
				/^Package: / { pkg = $2; file = ""; sha = "" }
				/^Filename: / { file = $2 }
				/^SHA256sum: / { sha = $2 }
				/^$/ { if (pkg == p && file == f && sha != "") { print sha; exit } }
				END { if (pkg == p && file == f && sha != "") print sha }' | head -n1)"
			[ -n "$sum" ] && break
		done
	fi
	echo "$sum"
}

installed_version() {
	if [ "$PM" = "apk" ]; then
		apk query --installed --fields name,version "$1" 2>/dev/null | awk -v p="$1" '$1 == "Name:" { n = $2 } $1 == "Version:" && n == p { print $2; exit }'
		return 0
	fi
	opkg list-installed 2>/dev/null | awk -v p="$1" '$1 == p { print $3; exit }'
}

# installed_list: "name version" of the installed packages Easy VLESS cares
# about (status summary)
installed_list() {
	if [ "$PM" = "apk" ]; then
		apk list -I 2>/dev/null | awk '{ print $1 }' | grep -E '^(easy-vless|luci-app-easy-vless|sing-box|dnsmasq)'
	else
		opkg list-installed 2>/dev/null | grep -E '^(easy-vless|luci-app-easy-vless|sing-box|dnsmasq)'
	fi
}

singbox_version() {
	/usr/bin/sing-box-lx version 2>/dev/null | sed -n '1s/^sing-box version //p'
}

# "dnsmasq -v" lists compile options separated by spaces, e.g. "nftset" or
# "no-nftset"; match the whole option (grep -w would also match "no-nftset").
# dnsmasq_nftset_supported "<output of dnsmasq --version>": true only when the
# compile time options list "nftset" (a dnsmasq without it lists "no-nftset",
# and its --help still mentions --nftset). Same logic as app.sh.
dnsmasq_nftset_supported() {
	echo "$1" | sed -n 's/^Compile time options://p' | tr ' \t' '\n\n' | grep -qx "nftset"
}
dnsmasq_has_nftset() { dnsmasq_nftset_supported "$(dnsmasq --version 2>/dev/null)"; }

# ask QUESTION: true on an interactive "y" (false without a terminal)
ask() {
	[ -t 0 ] || return 1
	printf '[easy-vless] %s [y/N] ' "$1"
	read -r answer
	case "$answer" in y|Y|yes|YES) return 0 ;; esac
	return 1
}

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{ print $1 }'; }

# any_exists PATH...: at least one of the (globbed) paths exists; "ls A B"
# fails in BusyBox as soon as one of them is missing
any_exists() {
	local f
	for f in "$@"; do [ -e "$f" ] && return 0; done
	return 1
}

# is_ip_literal HOST: an IPv4 address or a bracketed IPv6 address (no DNS)
is_ip_literal() {
	case "$1" in
		\[*\]) return 0 ;;
		""|*[!0-9.]*) return 1 ;;
	esac
	return 0
}

# url_host URL: host part of URL ("[2001:db8::1]" for an IPv6 literal)
url_host() {
	local h="${1#*://}"
	case "$h" in
		\[*\]*) echo "${h%%]*}]" ;;
		*) echo "${h%%[/:?]*}" ;;
	esac
}

now_epoch() { echo "${EV_TEST_NOW:-$(date +%s)}"; }

# ---------------------------------------------------------------- cleanup / rollback

# dnsmasq_rollback: reinstall the dnsmasq package that was removed for
# dnsmasq-full, from the copy downloaded before anything was changed
dnsmasq_rollback() {
	DNSMASQ_STAGE=""
	warn "restoring ${DNSMASQ_PKG:-dnsmasq} ..."
	local rc=0
	if [ "$PM" = apk ]; then
		if [ -n "$(installed_version dnsmasq-full)" ] && [ "$DNSMASQ_PKG" != dnsmasq-full ]; then
			apk del --network=no dnsmasq-full >&2 || rc=1
		fi
		if [ -n "${DNSMASQ_PKG:-}" ] && [ "$(installed_version "$DNSMASQ_PKG")" != "$OLD_DNS_VERSION" ]; then
			apk add --network=no --repositories-file /dev/null --repository "$WORKDIR/dnsmasq/packages.adb" "${DNSMASQ_PKG}=${OLD_DNS_VERSION}" >&2 || rc=1
		fi
		[ "$rc" != 0 ] || cp -p "$WORKDIR/dnsmasq/world" /etc/apk/world || rc=1
	else
		if [ -n "$(installed_version dnsmasq-full)" ] && [ "$DNSMASQ_PKG" != dnsmasq-full ]; then
			opkg remove dnsmasq-full >&2 || rc=1
		fi
		if [ -n "${OLD_IPK:-}" ] && [ "$(installed_version "$DNSMASQ_PKG")" != "$OLD_DNS_VERSION" ]; then
			opkg install "$WORKDIR/dnsmasq/$OLD_IPK" >&2 || rc=1
		fi
	fi
	if [ -f /etc/config/dhcp.easy-vless.bak ]; then
		cp -p /etc/config/dhcp.easy-vless.bak /etc/config/dhcp || rc=1
	fi
	if [ -n "${DNSMASQ_PKG:-}" ]; then
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || rc=1
	fi
	return "$rc"
}

rollback_easy_vless() {
	local p rc=0
	warn "restoring previous Easy VLESS packages and settings"
	if [ -x /etc/init.d/easy_vless ]; then
		/etc/init.d/easy_vless stop >&2 || rc=1
	fi
	if [ "$PM" = apk ]; then
		# Only the three byte-pinned v1.2.0 APKs qualify for legacy recovery.
		# Newer rollback files are verified and installed with normal trust.
		[ -z "$EV_LEGACY_APKS" ] ||
			apk add --allow-untrusted --network=no --repositories-file /dev/null $EV_LEGACY_APKS >&2 || rc=1
		[ -z "$EV_PREVIOUS_FILES" ] ||
			apk add --network=no --repositories-file /dev/null $EV_PREVIOUS_FILES >&2 || rc=1
	elif [ -n "$EV_PREVIOUS_FILES" ]; then
		opkg install --force-downgrade $EV_PREVIOUS_FILES >&2 || rc=1
	fi
	for p in luci-app-easy-vless easy-vless-sing-box easy-vless sing-box-lx; do
		case " $EV_ADDED " in
			*" $p "*)
				[ -z "$(installed_version "$p")" ] ||
					{ if [ "$PM" = apk ]; then apk del --network=no "$p"; else opkg remove "$p"; fi; } >&2 || rc=1
			;;
		esac
	done
	[ ! -f "$WORKDIR/easy_vless.config" ] ||
		cp -p "$WORKDIR/easy_vless.config" /etc/config/easy_vless || rc=1
	if [ -x /etc/init.d/easy_vless ]; then
		if [ "$EV_WAS_ENABLED" = 1 ]; then
			/etc/init.d/easy_vless enable >&2 || rc=1
		else
			/etc/init.d/easy_vless disable >&2 || rc=1
		fi
		/etc/init.d/rpcd restart >&2 || rc=1
	fi
	return "$rc"
}

on_exit() {
	local rc=$?
	trap - EXIT INT TERM HUP
	local keep=0
	if [ "$EV_STAGE" = active ]; then
		rollback_easy_vless || keep=1
	fi
	if [ "$DNSMASQ_STAGE" = "removed" ]; then
		dnsmasq_rollback || keep=1
	fi
	if [ "$EV_STAGE" = active ] && [ "${EV_WAS_RUNNING:-0}" = 1 ]; then
		/etc/init.d/easy_vless restart >&2 || keep=1
	fi
	if [ "$keep" = 0 ]; then
		[ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
	else
		warn "rollback could not be completed; recovery files kept in $WORKDIR"
	fi
	[ "$OPT_CHECK" = 1 ] || flock -u 8 2>/dev/null || :
	exit "$rc"
}
on_signal() { echo >&2; die "interrupted"; }
trap on_exit EXIT
trap on_signal INT TERM HUP

# ---------------------------------------------------------------- HTTPS diagnostics

# explain_download_error URL TEXT: reason and remedy for a failed HTTPS
# request, from the messages of uclient-fetch / opkg (verified against
# OpenWrt 24.10.3 uclient-fetch + libustream-mbedtls)
explain_download_error() {
	local url="$1" text="$2" host
	host="$(url_host "$url")"
	case "$text" in
		*"certificate is self-signed or not signed by a trusted CA"*)
			echo "the TLS certificate of ${host} is not trusted: the CA certificates are missing or outdated. Install the package ca-bundle (see the README section \"HTTPS на новом роутере\" (HTTPS on a new router) for a copy made on a PC); never disable certificate checks" ;;
		*"unknown error"*|*"not yet valid"*|*"has expired"*)
			echo "the TLS certificate of ${host} could not be verified - most likely the system time is wrong (now: $(date -u '+%Y-%m-%d %H:%M UTC')). Set the time, e.g. 'ntpd -n -q -p 0.openwrt.pool.ntp.org', and run the installer again" ;;
		*"SSL support not available"*)
			echo "wget (uclient-fetch) has no TLS backend: libustream-mbedtls (and ca-bundle) must be installed" ;;
		*"Operation not permitted"*|*"Failed to send request"*)
			if ! is_ip_literal "$host" && command -v nslookup >/dev/null 2>&1 && ! nslookup "$host" >/dev/null 2>&1; then
				echo "the name ${host} cannot be resolved (DNS). Check the internet connection and the DNS server of the router ('nslookup ${host}')"
			else
				echo "the connection to ${host} was refused by the router itself (\"Operation not permitted\"): a DNS failure or a firewall rule blocking the router's own traffic, e.g. a leftover proxy (PassWall/PassWall2, another Easy VLESS). Check 'nslookup ${host}' and 'nft list ruleset'"
			fi ;;
		*"HTTP error 404"*)
			echo "the file does not exist at this URL (HTTP 404): wrong release version, release not published yet, or missing asset" ;;
		*"HTTP error"*)
			echo "the server answered with an error ($(echo "$text" | grep -o 'HTTP error [0-9]*' | head -n1))" ;;
		*"timed out"*|*"Connection failed"*|*"reset"*|*"Connection error"*)
			echo "no connection to ${host}: check the internet connection of the router" ;;
		*"Signature check failed"*|*"usign"*)
			echo "the signature of the package lists could not be verified: the opkg keys (/etc/opkg/keys, package openwrt-keyring) or usign are missing" ;;
		*)
			echo "see the output above" ;;
	esac
}

# fetch URL FILE DESCRIPTION: HTTPS download with certificate verification,
# up to 3 attempts for network errors; FILE only appears when complete and
# not empty. Dies with a diagnosis otherwise.
fetch() {
	local url="$1" out="$2" what="$3" err n=0 rc text
	case "$url" in https://*) ;; *) die "refusing to download ${what} over a non-HTTPS URL: ${url}" ;; esac
	err="$WORKDIR/fetch.err"
	while :; do
		n=$((n + 1))
		rm -f "$out.part"
		wget -O "$out.part" "$url" >"$err" 2>&1
		rc=$?
		if [ "$rc" = "0" ] && [ -s "$out.part" ]; then
			mv -f "$out.part" "$out" || die "cannot write $out"
			return 0
		fi
		rm -f "$out.part"
		[ "$rc" = "0" ] && echo "empty response" >>"$err"
		text="$(grep -v -e '^Downloading ' -e '^Connecting to ' -e '^Writing to ' -e '^Redirected to ' -e '^$' "$err" | tail -n 3)"
		case "$text" in
			*"timed out"*|*"Connection failed"*|*"reset"*|*"Failed to send request"*|*"empty response"*)
				if [ "$n" -lt 3 ]; then sleep 3; continue; fi ;;
		esac
		break
	done
	echo "[easy-vless] ERROR: download failed: ${what}" >&2
	echo "[easy-vless]   URL:    ${url}" >&2
	echo "[easy-vless]   output: $(echo "${text:-wget exit code $rc}" | tr '\n' ' ')" >&2
	die "$(explain_download_error "$url" "$text")"
}

# ---------------------------------------------------------------- preflight

# arch_family ARCH: CPU family of an OpenWrt package architecture
# (DISTRIB_ARCH, e.g. aarch64_cortex-a53, arm_cortex-a7_neon-vfpv4,
# mipsel_24kc, x86_64); empty for an architecture this installer does not know
arch_family() {
	case "$1" in
		aarch64_*|aarch64) echo aarch64 ;;
		arm_*) echo arm ;;
		x86_64) echo x86_64 ;;
		i386_*) echo i386 ;;
		mips64_*|mips64el_*) echo mips64 ;;
		mips_*|mipsel_*) echo mips ;;
		riscv64_*) echo riscv64 ;;
		loongarch64_*) echo loongarch64 ;;
		powerpc64_*) echo powerpc64 ;;
		powerpc_*) echo powerpc ;;
		arc_*) echo arc ;;
	esac
}

# arch_matches_kernel: DISTRIB_ARCH is plausible for the running kernel
# (a copied /etc/openwrt_release or a wrong image must not make the
# installer fetch binaries for another CPU). uname -m: aarch64, armv7l,
# x86_64, i686, mips (both byte orders), mips64, riscv64, ppc, ...
arch_matches_kernel() {
	local m
	m="$(uname -m 2>/dev/null)"
	case "$(arch_family "$DISTRIB_ARCH")" in
		aarch64) [ "$m" = "aarch64" ] ;;
		arm) case "$m" in arm*|aarch64) return 0 ;; esac; return 1 ;;
		x86_64) [ "$m" = "x86_64" ] ;;
		i386) case "$m" in i?86) return 0 ;; esac; return 1 ;;
		mips64) [ "$m" = "mips64" ] ;;
		mips) [ "$m" = "mips" ] ;;
		riscv64) [ "$m" = "riscv64" ] ;;
		loongarch64) [ "$m" = "loongarch64" ] ;;
		powerpc64) [ "$m" = "ppc64" ] ;;
		powerpc) [ "$m" = "ppc" ] ;;
		arc) case "$m" in arc*) return 0 ;; esac; return 1 ;;
		*) return 1 ;;
	esac
}

# release_series RELEASE: "24.10" for 24.10.3 or 24.10.0-rc7 (numbers, no
# leading zeros); empty for SNAPSHOT or anything else that is not
# <number>.<number>[.<number>][-rc<number>]
release_series() {
	echo "$1" | awk '/^[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?$/ { split($0, v, /[.-]/); print (v[1] + 0) "." (v[2] + 0) }'
}

# release_stable RELEASE: a stable release <number>.<number>.<number>
# (24.10.0, 25.12.6), not a release candidate or snapshot
release_stable() {
	echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'
}

# series_channel SERIES: the package manager of a supported release series
# ("24.10" -> opkg, "25.12" -> apk),
# empty when it is not supported
series_channel() {
	local e
	[ -n "$1" ] || return 0
	for e in $SUPPORTED_SERIES; do
		[ "${e%%:*}" = "$1" ] && { echo "${e#*:}"; return 0; }
	done
	return 0
}

# apk_arches: the package architectures apk installs for, one per line, from
# /etc/apk/arch (the OpenWrt image build writes it from ARCH_PACKAGES, the same
# value as DISTRIB_ARCH: aarch64_cortex-a53, mipsel_24kc, x86_64, ...)
apk_arches() {
	awk '{ sub(/#.*/, ""); for (i = 1; i <= NF; i++) print $i }' "$APK_ARCH_FILE" 2>/dev/null
}

# apk_cpu_family: CPU family of the apk binary itself ("apk --print-arch" is
# the architecture apk was compiled for - aarch64, armv7, armel, mips, mipsel,
# x86_64, ... - not the OpenWrt package architecture; it does not read
# /etc/apk/arch). Empty when unknown.
apk_cpu_family() {
	case "$(apk --print-arch 2>/dev/null | head -n1)" in
		aarch64) echo aarch64 ;;
		armv7|armhf|armel) echo arm ;;
		x86_64) echo x86_64 ;;
		x86) echo i386 ;;
		mips|mipsel) echo mips ;;
		mips64|mips64el) echo mips64 ;;
		riscv64) echo riscv64 ;;
		loongarch64) echo loongarch64 ;;
		ppc) echo powerpc ;;
		ppc64) echo powerpc64 ;;
	esac
}

# check_apk_arch: apk installs packages for exactly this router: DISTRIB_ARCH
# is in /etc/apk/arch, no other CPU architecture is listed there, the
# installed packages (base-files, kernel, libc, ...) are DISTRIB_ARCH or
# noarch, and the apk binary is built for the CPU family of DISTRIB_ARCH.
# Stops before anything is changed.
check_apk_arch() {
	local list extra fam own foreign
	list="$(apk_arches)"
	[ -n "$list" ] || die "$APK_ARCH_FILE is missing or empty - apk does not know the package architecture of this router (/etc/openwrt_release: ${DISTRIB_ARCH}). Nothing was changed."
	echo "$list" | grep -qxF "$DISTRIB_ARCH" \
		|| die "apk installs packages for '$(echo "$list" | tr '\n' ' ' | sed 's/ $//')' ($APK_ARCH_FILE), /etc/openwrt_release says ${DISTRIB_ARCH} - the release information does not fit this firmware. Nothing was changed."
	extra="$(echo "$list" | grep -vxF -e "$DISTRIB_ARCH" -e noarch | tr '\n' ' ' | sed 's/ $//')"
	[ -z "$extra" ] || die "$APK_ARCH_FILE contains other CPU architectures: $extra"
	foreign="$(apk query --installed --fields name,arch '*' 2>/dev/null | awk -v a="$DISTRIB_ARCH" '
		$1 == "Name:" { n = $2 }
		$1 == "Arch:" { if ($2 != a && $2 != "noarch") printf " %s(%s)", n, $2 }')"
	[ -z "$foreign" ] || die "installed packages of another architecture than ${DISTRIB_ARCH}:$foreign"
	fam="$(apk_cpu_family)"
	own="$(arch_family "$DISTRIB_ARCH")"
	[ -n "$fam" ] && [ "$fam" = "$own" ] ||
		die "the apk CPU family does not match ${DISTRIB_ARCH}"
	say "apk architecture: ${DISTRIB_ARCH} ($APK_ARCH_FILE; apk built for $(apk --print-arch 2>/dev/null | head -n1)) - ok"
}

# detect_channel: PM (opkg or apk) from the OpenWrt release and the package
# manager that is present; stops on every inconsistency before anything is
# changed.
detect_channel() {
	local series want have_opkg=0 have_apk=0 v a
	command -v opkg >/dev/null 2>&1 && have_opkg=1
	if command -v apk >/dev/null 2>&1; then
		v="$(apk --version 2>/dev/null | head -n1)"
		case "$v" in
			"apk-tools 3."*) have_apk=1 ;;
			*) die "an apk command was found, but it is not apk-tools 3 ('${v:-no version}') - not the package manager of OpenWrt 25.12. Nothing was changed." ;;
		esac
	fi
	series="$(release_series "${DISTRIB_RELEASE:-}")"
	want="$(series_channel "$series")"
	if [ -n "$want" ] && ! release_stable "${DISTRIB_RELEASE:-}"; then
		[ "$OPT_FORCE" = "1" ] || die "OpenWrt ${DISTRIB_RELEASE} is a release candidate, not a stable release - not supported by this installer (supported: stable ${SUPPORTED_RELEASE}). Use --force to try anyway."
		warn "OpenWrt ${DISTRIB_RELEASE} is a release candidate - continuing with ${want} because of --force"
	fi
	if [ -z "$want" ]; then
		[ "$OPT_FORCE" = "1" ] || die "OpenWrt ${DISTRIB_RELEASE:-unknown} is not supported by this installer (supported: stable 24.x with opkg, stable 25.x with apk). Use --force to try anyway."
		case "${have_opkg}${have_apk}" in
			10) want=opkg ;;
			01) want=apk ;;
			11) die "both opkg and apk are installed on OpenWrt ${DISTRIB_RELEASE:-unknown} - it is not clear which one manages the packages. Nothing was changed." ;;
			*) die "neither opkg nor apk was found on OpenWrt ${DISTRIB_RELEASE:-unknown}. Nothing was changed." ;;
		esac
		warn "OpenWrt ${DISTRIB_RELEASE:-unknown} is not a tested release - continuing with ${want} because of --force"
	fi
	case "$want" in
		opkg)
			[ "$have_opkg" = 1 ] || die "opkg is required; provision it before running this installer"
			[ "$have_apk" = "0" ] || die "/etc/openwrt_release says OpenWrt ${DISTRIB_RELEASE} (package manager opkg), but apk is installed - the release information does not fit this firmware. Nothing was changed."
			;;
		apk)
			[ "$have_apk" = "1" ] || die "OpenWrt ${DISTRIB_RELEASE} uses the package manager apk, but apk was not found - the release information does not fit this firmware. Nothing was changed."
			[ "$have_opkg" = "0" ] || die "OpenWrt ${DISTRIB_RELEASE} uses apk, but opkg is installed as well - it is not clear which one manages the packages. Nothing was changed."
			check_apk_arch
			;;
	esac
	PM="$want"
	if [ "$PM" = "apk" ]; then say "package manager: apk (Easy VLESS .apk packages)"; else say "package manager: opkg (Easy VLESS .ipk packages)"; fi
}

# ---------------------------------------------------------------- system detection

# kernel_log: kernel messages (boot messages included while they are still
# in the ring buffer)
kernel_log() {
	if [ -n "$SYS" ]; then cat "$SYS/dmesg.txt" 2>/dev/null; return 0; fi
	dmesg 2>/dev/null
}

# fs_space MOUNTPOINT: "<size KB> <available KB>" of the filesystem (POSIX
# df output; the last line, so a long device name cannot shift the fields)
fs_space() {
	{ df -Pk "$1" 2>/dev/null || df -k "$1" 2>/dev/null; } | awk 'NR > 1 { s = $(NF - 4); a = $(NF - 2) } END { if (s != "") print s, a }'
}

# detect_ram: RAM_KB = MemTotal, or the memory limit of this process' control
# group when that is lower (a container or a memory-limited service)
detect_ram() {
	local cg lim
	RAM_AVAILABLE_KB="$(awk '$1 == "MemAvailable:" { print $2; exit }' "$SYS/proc/meminfo" 2>/dev/null)"
	RAM_KB="$(awk '$1 == "MemTotal:" { print $2; exit }' "$SYS/proc/meminfo" 2>/dev/null)"
	RAM_HOW="MemTotal"
	[ -z "$SYS" ] || return 0
	cg="$(sed -n 's/^0::\(.*\)$/\1/p' /proc/self/cgroup 2>/dev/null | head -n1)"
	[ -n "$cg" ] || return 0
	lim="$(cat "/sys/fs/cgroup${cg%/}/memory.max" 2>/dev/null)"
	case "$lim" in ""|*[!0-9]*) return 0 ;; esac
	lim="$(awk -v b="$lim" 'BEGIN { printf "%d", b / 1024 }')"
	if [ -z "$RAM_KB" ] || [ "$lim" -lt "$RAM_KB" ]; then
		RAM_KB="$lim"
		RAM_HOW="memory limit of the control group"
	fi
}

# detect_overlay: mount point (/overlay, or / without an overlay), device and
# filesystem type of the filesystem that packages are installed to
detect_overlay() {
	OVL_MNT=/
	awk '$2 == "/overlay" { f = 1 } END { exit !f }' "$SYS/proc/mounts" 2>/dev/null && OVL_MNT=/overlay
	OVL_DEV="$(awk -v m="$OVL_MNT" '$2 == m { d = $1 } END { print d }' "$SYS/proc/mounts" 2>/dev/null)"
	OVL_FS="$(awk -v m="$OVL_MNT" '$2 == m { t = $3 } END { print t }' "$SYS/proc/mounts" 2>/dev/null)"
	set -- $(fs_space "$OVL_MNT")
	OVL_SIZE_KB="${1:-}"
	OVL_FREE_KB="${2:-}"
}

# flash_chip_kb: size of the flash chip printed by the NAND, SPI-NAND and
# SPI-NOR drivers at boot ("... 128 MiB, block size: 128 KiB ...",
# "nand: 128 MiB, SLC, ...", "spi-nor spi0.0: w25q128 (16384 Kbytes)")
flash_chip_kb() {
	kernel_log | awk '
		{ kb = 0 }
		match($0, /[0-9]+ MiB, (block size|SLC|MLC|erase size)/) { kb = substr($0, RSTART, RLENGTH) + 0; kb *= 1024 }
		match($0, /\([0-9]+ Kbytes\)/) { kb = substr($0, RSTART + 1, RLENGTH - 1) + 0 }
		kb > max { max = kb }
		END { if (max > 0) print max }'
}

# ubi_chip_kb N: size of the flash chip under UBI device N. UBI reserves
# eraseblocks for bad blocks in proportion to the WHOLE chip
# (CONFIG_MTD_UBI_BEB_LIMIT: 20 per 1024 eraseblocks of the chip), so
# (reserved_for_bad + bad_peb_count) * 1024 / 20 eraseblocks is the chip size
# (a lower bound when UBI could not reserve all of them).
ubi_chip_kb() {
	local d="$SYS/sys/class/ubi/ubi$1" rsv bad mtd peb
	rsv="$(cat "$d/reserved_for_bad" 2>/dev/null)"
	bad="$(cat "$d/bad_peb_count" 2>/dev/null)"
	mtd="$(cat "$d/mtd_num" 2>/dev/null)"
	peb="$(cat "$SYS/sys/class/mtd/mtd$mtd/erasesize" 2>/dev/null)"
	[ -n "$rsv" ] && [ -n "$bad" ] && [ -n "$peb" ] || return 0
	awk -v r="$rsv" -v b="$bad" -v e="$peb" 'BEGIN { if (r + b > 0) printf "%d\n", (r + b) * 1024 / 20 * e / 1024 }'
}

# mtd_extent_kb: the flash chip is at least as large as its partition layout
# (end of the last partition; the chip size itself is not in sysfs)
mtd_extent_kb() {
	local m size off max=0
	for m in "$SYS"/sys/class/mtd/mtd*; do
		case "$m" in *ro) continue ;; esac
		size="$(cat "$m/size" 2>/dev/null)" || continue
		off="$(cat "$m/offset" 2>/dev/null)"
		size="$(awk -v s="$size" -v o="${off:-0}" 'BEGIN { printf "%d", (s + o) / 1024 }')"
		[ "$size" -gt "$max" ] && max="$size"
	done
	[ "$max" -gt 0 ] && echo "$max"
}

# disk_kb DEVICE: size of the whole disk holding DEVICE (sda2 -> sda,
# mmcblk0p2 -> mmcblk0); without DEVICE: the largest real disk
disk_kb() {
	local dev="${1#/dev/}" b name
	for b in "$SYS"/sys/block/*; do
		name="${b##*/}"
		case "$name" in loop*|ram*|zram*|mtdblock*|ubiblock*|dm-*|nbd*|sr*|fd*|md*|mmcblk*boot*|mmcblk*rpmb) continue ;; esac
		if [ -n "$dev" ] && [ "$dev" != "$name" ] && [ ! -e "$b/$dev" ]; then continue; fi
		cat "$b/size" 2>/dev/null
	done | awk '$1 + 0 > m { m = $1 + 0 } END { if (m > 0) printf "%d\n", m / 2 }'
}

# detect_storage: STORAGE_KB (total flash/disk size), STORAGE_HOW (source),
# STORAGE_EXACT (1: measured, 0: only a lower bound is known)
detect_storage() {
	local kb n
	STORAGE_KB=""; STORAGE_HOW=""; STORAGE_EXACT=0
	case "$OVL_FS" in
		ubifs|jffs2)
			kb="$(flash_chip_kb)"
			if [ -n "$kb" ]; then
				STORAGE_KB="$kb"; STORAGE_HOW="flash chip (kernel log)"; STORAGE_EXACT=1; return 0
			fi
			if [ "$OVL_FS" = ubifs ]; then
				n="$(echo "$OVL_DEV" | sed -n 's#^\(/dev/\)\{0,1\}ubi\([0-9][0-9]*\).*#\2#p')"
				[ -n "$n" ] || n=0
				kb="$(ubi_chip_kb "$n")"
				if [ -n "$kb" ]; then
					STORAGE_KB="$kb"; STORAGE_HOW="flash chip (UBI bad-block reserve)"; STORAGE_EXACT=1; return 0
				fi
			fi
			kb="$(mtd_extent_kb)"
			[ -n "$kb" ] && { STORAGE_KB="$kb"; STORAGE_HOW="MTD partition layout (lower bound)"; }
			;;
		*)
			kb="$(disk_kb "$OVL_DEV")"
			[ -n "$kb" ] || kb="$(disk_kb "")"
			[ -n "$kb" ] && { STORAGE_KB="$kb"; STORAGE_HOW="disk"; STORAGE_EXACT=1; }
			;;
	esac
	return 0
}

mb() { awk -v k="${1:-0}" 'BEGIN { printf "%.1f", k / 1024 }'; }
size_or_unknown() { if [ -n "$1" ]; then echo "$(mb "$1") MB"; else echo "unknown"; fi; }

# check_system_requirements: RAM and flash size (before anything is changed
# or downloaded)
check_system_requirements() {
	local tmp_free
	detect_ram
	detect_overlay
	detect_storage
	say "RAM: $(size_or_unknown "$RAM_KB") (${RAM_HOW}), required: ${MIN_RAM_MB} MB"
	say "flash/storage: $(size_or_unknown "$STORAGE_KB")${STORAGE_HOW:+ (${STORAGE_HOW})}, required: ${MIN_STORAGE_MB} MB"
	say "overlay: ${OVL_MNT} (${OVL_FS:-?} on ${OVL_DEV:-?}), size $(size_or_unknown "$OVL_SIZE_KB"), free $(size_or_unknown "$OVL_FREE_KB")"
	[ -n "$RAM_KB" ] || die "cannot read the RAM size (MemTotal in /proc/meminfo)"
	if [ "$RAM_KB" -lt "$MIN_RAM_KB" ]; then
		die "not enough RAM: $(mb "$RAM_KB") MB (${RAM_HOW}), required: ${MIN_RAM_MB} MB installed RAM (the kernel reports at least $((MIN_RAM_KB / 1024)) MB on such a router). Nothing was changed."
	fi
	if [ -z "$STORAGE_KB" ]; then
		warn "the flash/storage size could not be determined - only the free space is checked"
	elif [ "$STORAGE_KB" -lt "$MIN_STORAGE_KB" ]; then
		[ "$STORAGE_EXACT" = "1" ] && die "flash/storage too small: $(mb "$STORAGE_KB") MB (${STORAGE_HOW}), required: at least ${MIN_STORAGE_MB} MB. Nothing was changed."
		warn "flash size: at least $(mb "$STORAGE_KB") MB (${STORAGE_HOW}; the chip size is no longer in the kernel log) - only the free space is checked"
	fi
	[ -n "$OVL_FREE_KB" ] || die "cannot determine the free space of ${OVL_MNT} (df)"
	# The largest selected bundle is under 16 MiB before official dependencies.
	# Leave room to stage it before the precise post-download checks.
	set -- $(fs_space /tmp)
	tmp_free="${2:-0}"
	[ "$tmp_free" -ge 20480 ] || die "not enough free space in /tmp for release staging (minimum 20 MiB)"
	[ -z "$RAM_AVAILABLE_KB" ] || [ "$RAM_AVAILABLE_KB" -ge 20480 ] ||
		die "not enough available RAM for release staging (minimum 20 MiB)"
}

https_probe() {
	local out="$WORKDIR/probe.out" err="$WORKDIR/probe.err"
	rm -f "$out"
	if wget -O "$out" "$1" >"$err" 2>&1 && [ -s "$out" ]; then
		HTTPS_ERR=""
		return 0
	fi
	HTTPS_ERR="$(grep -v -e '^Downloading ' -e '^Connecting to ' -e '^Writing to ' -e '^Redirected to ' -e '^$' "$err" | tail -n 3)"
	[ -n "$HTTPS_ERR" ] || HTTPS_ERR="empty response"
	return 1
}

# https_probe_url: the signature file of this router's core package feed
# (small, always present), or of the official archive when no feed is set up
https_probe_url() {
	local u
	if [ "$PM" = "apk" ]; then
		# the target's own package index (small)
		u="$(official_feeds | awk '$1 == "core" { print $2; exit }')"
		[ -n "$u" ] || u="$(official_feeds | awk '{ print $2; exit }')"
		[ -n "$u" ] || u="https://downloads.openwrt.org/releases/${DISTRIB_RELEASE}/targets/${DISTRIB_TARGET}/packages/packages.adb"
		echo "$u"
		return 0
	fi
	u="$(awk '$1 ~ /^src/ && $2 == "openwrt_core" { print $3; exit }' /etc/opkg/distfeeds.conf 2>/dev/null)"
	[ -n "$u" ] || u="$(awk '$1 ~ /^src/ && NF >= 3 { print $3; exit }' /etc/opkg/distfeeds.conf 2>/dev/null)"
	[ -n "$u" ] || u="${OPKG_ARCHIVE}/${DISTRIB_RELEASE}/packages/${DISTRIB_ARCH}/base"
	echo "${u%/}/Packages.sig"
}

# tls_packages_missing TEXT: the HTTPS error means a missing TLS backend or
# missing/outdated CA certificates, i.e. something packages can fix
tls_packages_missing() {
	case "$1" in
		*"SSL support not available"*|*"not signed by a trusted CA"*) return 0 ;;
	esac
	return 1
}

# check_https: does HTTPS with certificate verification work on this router?
# (a functional test - which TLS library provides it does not matter).
# A missing TLS backend / CA bundle is remembered for ensure_https, every
# other failure (time, DNS, firewall, network) stops here with a diagnosis.
check_https() {
	command -v wget >/dev/null 2>&1 || die "wget (uclient-fetch) not found - install uclient-fetch, libustream-mbedtls and ca-bundle"
	HTTPS_URL="$(https_probe_url)"
	if https_probe "$HTTPS_URL"; then
		say "HTTPS: ${HTTPS_URL} - ok (certificate verified)"
		return 0
	fi
	if tls_packages_missing "$HTTPS_ERR"; then
		HTTPS_BROKEN=1
		warn "HTTPS does not work: $(echo "$HTTPS_ERR" | tr '\n' ' ')"
		return 0
	fi
	echo "[easy-vless] ERROR: HTTPS test failed" >&2
	echo "[easy-vless]   URL:    ${HTTPS_URL}" >&2
	echo "[easy-vless]   output: $(echo "$HTTPS_ERR" | tr '\n' ' ')" >&2
	die "$(explain_download_error "$HTTPS_URL" "$HTTPS_ERR")"
}

check_dns() {
	local h
	command -v nslookup >/dev/null 2>&1 || return 0
	for h in "$@"; do
		is_ip_literal "$h" && continue
		nslookup "$h" >/dev/null 2>&1 || die "the name $h cannot be resolved (DNS): check the internet connection and the DNS server of the router ('nslookup $h'). uclient-fetch reports this as \"Operation not permitted\""
	done
}

# resolve_base_url: when the release files are downloaded from the default
# github.com URL and github.com cannot be reached (some providers block the
# github.com network while the GitHub CDN that serves the assets stays up),
# switch EV_BASE_URL to the first working mirror in EV_MIRRORS. Runs only for
# the default base URL: --base-url (USER_BASE_URL=1), --local and --no-mirror
# all disable it. Only a connection-level failure triggers the search; a 404 or
# a TLS error is a different problem and is left for the normal fetch to report.
# Integrity is still enforced by SHA256SUMS afterwards (see the EV_MIRRORS note).
resolve_base_url() {
	local m cand
	[ -z "$OPT_LOCAL" ] || return 0
	[ "${HTTPS_BROKEN:-0}" = "0" ] || return 0
	[ "$OPT_NO_MIRROR" = "0" ] || return 0
	[ "$USER_BASE_URL" = "0" ] || return 0
	case "$EV_BASE_URL" in https://github.com/*) ;; *) return 0 ;; esac

	# A real request for the release index: if github.com answers, keep it.
	https_probe "${EV_BASE_URL}/SHA256SUMS" && return 0
	# Fall back only when github.com is unreachable, not on 404/TLS/other errors.
	case "$HTTPS_ERR" in
		*"timed out"*|*"Connection failed"*|*"reset"*|*"refused"*|*"No route"*|*"unreachable"*|*"Connection error"*|*"Failed to send request"*) ;;
		*) return 0 ;;
	esac

	warn "github.com is not reachable (${HTTPS_ERR}) - trying a GitHub mirror"
	for m in $EV_MIRRORS; do
		case "$m" in https://?*) ;; *) continue ;; esac
		m="${m%/}"
		cand="${m}/${EV_BASE_URL}"
		if https_probe "${cand}/SHA256SUMS"; then
			EV_BASE_URL="$cand"
			warn "github.com blocked: using HTTPS mirror ${m} with the supplied manifest digest"
			return 0
		fi
	done
	# Nothing reachable: leave EV_BASE_URL on github.com so the download below
	# fails with the usual precise diagnosis instead of a mirror's error.
	warn "no GitHub mirror reachable either - continuing with github.com"
	return 0
}

# ---------------------------------------------------------------- feeds

# apk_feeds FILE...: "<name> <url>" of each configured repository.
apk_feeds() {
	cat "$@" 2>/dev/null | awk '$1 ~ /^https?:\/\// {
		n = $1; sub(/\/packages\.adb$/, "", n)
		if (n ~ /\/targets\/.*\/kmods\//) n = "kmods"
		else if (n ~ /\/targets\/.*\/packages$/) n = "core"
		else sub(/^.*\//, "", n)
		print n, $1 }'
}

# official_feeds: "<name> <url>" of the official package feeds of this router
official_feeds() {
	if [ "$PM" = "apk" ]; then
		apk_feeds "$APK_DISTFEEDS"
	else
		awk '$1 ~ /^src/ && NF >= 3 { print $2, $3 }' /etc/opkg/distfeeds.conf 2>/dev/null
	fi
}

# all_feeds: official and custom package feeds
all_feeds() {
	if [ "$PM" = "apk" ]; then
		apk_feeds /etc/apk/repositories.d/*.list /etc/apk/repositories
	else
		cat /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf 2>/dev/null | awk '$1 ~ /^src/ && NF >= 3 { print $2, $3 }'
	fi
}

# apk_update: like opkg_update - the feeds Easy VLESS needs (core, kmods,
# base, packages, luci) must be available, others are optional. apk verifies
# the signature of every index with /etc/apk/keys.
apk_update() {
	local log="$WORKDIR/apk-update.log" feeds name url bad="" soft="" text rc
	feeds="$WORKDIR/feeds"
	all_feeds >"$feeds"
	[ -s "$feeds" ] || die "no package feeds configured in $APK_DISTFEEDS"
	say "apk update ..."
	apk update >"$log" 2>&1
	rc=$?
	while read -r name url; do
		grep -E '^(WARNING|ERROR)' "$log" | grep -qF "$url" || continue
		case "$name" in
			core|kmods|base|packages|luci) bad="$bad $name" ;;
			*) soft="$soft $name" ;;
		esac
	done <"$feeds"
	text="$(grep -E '^(WARNING|ERROR)' "$log" | head -n 3)"
	if [ -n "$bad" ]; then
		echo "[easy-vless] ERROR: apk update: required package feeds not available:${bad}" >&2
		[ -n "$text" ] && echo "[easy-vless]   apk: $(echo "$text" | tr '\n' ' ')" >&2
		# shellcheck disable=SC2086
		set -- $bad
		die "$(explain_download_error "$(awk -v n="$1" '$1 == n { print $2; exit }' "$feeds")" "$text") (see upstream error above)"
	fi
	[ -z "$soft" ] || warn "optional package feeds not available:${soft} (not needed by Easy VLESS; see $log)"
	[ "$rc" = "0" ] || [ -n "$soft" ] || die "apk update failed: $(echo "${text:-exit code $rc}" | tr '\n' ' ') (see upstream error above)"
}

pm_update() {
	if [ "$PM" = "apk" ]; then apk_update; else opkg_update; fi
}

# ---------------------------------------------------------------- opkg update

# opkg_update: the feeds Easy VLESS needs (core/kmods/base/packages/luci)
# must be available; other feeds (routing, telephony, custom) are optional
opkg_update() {
	local log="$WORKDIR/opkg-update.log" lists feeds name url bad="" soft="" text
	lists="$WORKDIR/opkg-lists"
	feeds="$WORKDIR/feeds"
	cat /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf 2>/dev/null | awk '$1 ~ /^src/ && NF >= 3 { print $2, $3 }' >"$feeds"
	[ -s "$feeds" ] || die "no package feeds configured in /etc/opkg/distfeeds.conf"
	say "opkg update ..."
	grep -qsE '^option[[:space:]]+check_signature([[:space:]]|$)' /etc/opkg.conf ||
		die "enable opkg feed signature checking before installation"
	opkg update >"$log" 2>&1
	while read -r name url; do
		[ -s "$lists/$name" ] && [ -s "$lists/$name.sig" ] && continue
		case "$url" in
			*/base|*/packages|*/luci|*/kmods/*) bad="$bad $name" ;;
			*) soft="$soft $name" ;;
		esac
	done <"$feeds"
	if [ -n "$bad" ]; then
		text="$(grep -E 'SSL|Operation not permitted|Failed to send|HTTP error|timed out|Signature|usign|Connection' "$log" | head -n 3)"
		echo "[easy-vless] ERROR: opkg update: required package feeds not available:${bad}" >&2
		[ -n "$text" ] && echo "[easy-vless]   opkg: $(echo "$text" | tr '\n' ' ')" >&2
		# shellcheck disable=SC2086
		set -- $bad
		die "$(explain_download_error "$(awk -v n="$1" '$1 == n { print $2; exit }' "$feeds")" "$text") (see upstream error above)"
	fi
	[ -z "$soft" ] || warn "optional package feeds not available:${soft} (not needed by Easy VLESS; see $log)"
}

# check_feeds: the official package feeds in /etc/opkg/distfeeds.conf must be
# the ones of this router (release, target, architecture): feeds of another
# architecture give binaries for another CPU, of another target or release
# kernel modules that do not load (typical after a sysupgrade that kept an
# old distfeeds.conf, or a file copied from another router). Feeds with other
# URLs (mirrors with another layout, custom feeds) are not judged here; the
# dependency resolution in check_space verifies what they offer.
check_feeds() {
	local name url rel rest bad="" conf=/etc/opkg/distfeeds.conf
	[ "$PM" = "apk" ] && conf="$APK_DISTFEEDS"
	[ -s "$conf" ] && [ -n "$(official_feeds)" ] || die "$conf is missing or empty - configure the official package feeds of OpenWrt ${DISTRIB_RELEASE} first"
	while read -r name url; do
		case "$url" in
			*/releases/*/packages/*|*/releases/*/targets/*) ;;
			*) continue ;;
		esac
		rel="${url#*/releases/}"; rest="${rel#*/}"; rel="${rel%%/*}"
		[ "$rel" = "$DISTRIB_RELEASE" ] || bad="${bad}
  ${name}: release ${rel}, this router runs ${DISTRIB_RELEASE} (${url})"
		case "$rest" in
			packages/*)
				rest="${rest#packages/}"
				[ "${rest%%/*}" = "$DISTRIB_ARCH" ] || bad="${bad}
  ${name}: architecture ${rest%%/*}, this router is ${DISTRIB_ARCH} (${url})"
				;;
			targets/*)
				rest="${rest#targets/}"
				case "$rest/" in
					"${DISTRIB_TARGET}/"*) ;;
					*) bad="${bad}
  ${name}: target $(echo "$rest" | cut -d/ -f1-2), this router is ${DISTRIB_TARGET} (${url})" ;;
				esac
				;;
		esac
	done <<EOF
$(official_feeds)
EOF
	if [ -n "$bad" ]; then
		echo "[easy-vless] package feeds in $conf that do not belong to this router:${bad}" >&2
		die "restore the package feeds of OpenWrt ${DISTRIB_RELEASE} ${DISTRIB_TARGET} ${DISTRIB_ARCH} in $conf"
	fi
	say "package feeds: OpenWrt ${DISTRIB_RELEASE}, target ${DISTRIB_TARGET}, architecture ${DISTRIB_ARCH} - ok"
}

# ---------------------------------------------------------------- free space

# lists_stream: the downloaded package indexes of all feeds
lists_stream() {
	local l
	for l in "$WORKDIR/opkg-lists"/*; do
		[ -f "$l" ] || continue
		case "$l" in *.sig) continue ;; esac
		{ gzip -dc "$l" 2>/dev/null || cat "$l"; }
		echo
	done
}

# resolve_new NAME...: every package that "opkg install NAME..." adds to this
# router - NAMEs and their dependencies, recursively, from the feed indexes -
# that is not installed yet. Output: "<package> <architecture> <installed
# size in bytes> <download size in bytes>" per package, "MISSING <dependency>"
# for a dependency that no feed provides.
resolve_new() {
	{ cat "$OPKG_STATUS" 2>/dev/null; echo; echo "@@LISTS@@"; [ "$OPT_OFFLINE" = 1 ] || lists_stream; } | awk -v want="$*" '
		function clean(s) { gsub(/\([^)]*\)/, "", s); gsub(/[ \t]/, "", s); return s }
		function flush(   n, a, i, q) {
			if (p == "") return
			if (!lists) {
				if (st ~ / installed$/) {
					have[p] = 1
					n = split(prv, a, ","); for (i = 1; i <= n; i++) { q = clean(a[i]); if (q != "") have[q] = 1 }
				}
			} else if (!(p in dep)) {
				dep[p] = d; arch[p] = ar; isz[p] = sz + 0; dsz[p] = dl + 0; pv[p] = prv
				n = split(prv, a, ","); for (i = 1; i <= n; i++) { q = clean(a[i]); if (q != "" && !(q in prov)) prov[q] = p }
			}
			p = ""
		}
		$0 == "@@LISTS@@" { flush(); lists = 1; next }
		/^Package: / { flush(); p = $2; d = ""; prv = ""; sz = 0; dl = 0; st = ""; ar = ""; next }
		/^Depends: / { d = substr($0, 10); next }
		/^Provides: / { prv = substr($0, 11); next }
		/^Installed-Size: / { sz = $2; next }
		/^Size: / { dl = $2; next }
		/^Architecture: / { ar = $2; next }
		/^Status: / { st = $0; next }
		END {
			flush()
			nq = split(want, q, " ")
			for (h = 1; h <= nq; h++) {
				na = split(q[h], alt, "|"); ok = 0
				for (j = 1; j <= na; j++) { x = clean(alt[j]); if (x in have) { ok = 1; break } }
				if (ok) continue
				pick = ""
				for (j = 1; j <= na && pick == ""; j++) { x = clean(alt[j]); if (x in dep) pick = x; else if (x in prov) pick = prov[x] }
				if (pick == "") { print "MISSING", clean(alt[1]); continue }
				if (pick in have) continue
				have[pick] = 1
				m = split(pv[pick], a, ","); for (k = 1; k <= m; k++) { x = clean(a[k]); if (x != "") have[x] = 1 }
				print pick, arch[pick], isz[pick], dsz[pick]
				m = split(dep[pick], a, ","); for (k = 1; k <= m; k++) if (a[k] ~ /[^ \t]/) q[++nq] = a[k]
			}
		}'
}

# ipk_control IPK FIELD: a field of the control file inside an .ipk
ipk_control() {
	local d="$WORKDIR/ctl.$$"
	rm -rf "$d"; mkdir -p "$d" || return 1
	tar -xzf "$1" -C "$d" ./control.tar.gz 2>/dev/null || tar -xzf "$1" -C "$d" 2>/dev/null || { rm -rf "$d"; return 1; }
	tar -xzf "$d/control.tar.gz" -C "$d" 2>/dev/null
	sed -n "s/^$2: //p" "$d/control" 2>/dev/null | head -n1
	rm -rf "$d"
}

# check_space: resolve dnsmasq-full, the Easy VLESS packages and their
# dependencies from the
# feeds of this router) and compare the worst-case installed size with the
# free space of the overlay; the downloads go to /tmp (RAM).
check_space() {
	local wants="" own_kb=0 p f dep sz res missing wrong files=""
	if [ "$PM" = "apk" ]; then check_space_apk; return; fi
	for p in $EV_PACKAGES; do
		f="$PKGDIR/$(pkg_file "$p")"
		files="$files $f"
		sz="$(ipk_control "$f" Installed-Size)"
		dep="$(ipk_control "$f" Depends)"
		[ -n "$sz" ] || die "cannot read the control data of $(basename "$f")"
		own_kb=$((own_kb + sz / 1024 + 1))
		wants="$wants $(echo "$dep" | sed 's/([^)]*)//g; s/ //g; s/,/ /g')"
	done
	# the packages Easy VLESS itself provides are not taken from the feeds
	wants="$(for p in $wants; do case "$p" in sing-box-lx|easy-vless|easy-vless-sing-box|luci-app-easy-vless) ;; *) echo "$p" ;; esac; done)"
	if [ "$OPT_OFFLINE" = 1 ]; then
		res="$(resolve_new $wants)"
		[ -z "$res" ] || die "--offline dependencies are not installed: $(echo "$res" | awk '{print $2}' | tr '\n' ' ')"
		opkg --noaction install $files > "$WORKDIR/opkg-simulate.log" 2>&1 || {
			cat "$WORKDIR/opkg-simulate.log" >&2
			die "opkg cannot satisfy the versioned dependencies offline"
		}
		space_verdict "" "$own_kb" 2048
		return
	fi
	# dnsmasq-full: installed in this run (or, with --check, proposed)
	[ "$NEED_DNSMASQ" = "1" ] && wants="$wants dnsmasq-full"
	# shellcheck disable=SC2086
	res="$(resolve_new $wants)"
	missing="$(echo "$res" | awk '$1 == "MISSING" { printf " %s", $2 }')"
	[ -z "$missing" ] || die "dependencies not available in the package feeds of this router (${DISTRIB_ARCH}):${missing} - Easy VLESS cannot be installed on this architecture/firmware with the official feeds"
	wrong="$(echo "$res" | awk -v a="$DISTRIB_ARCH" 'NF == 4 && $2 != a && $2 != "all" && $2 != "noarch" { printf " %s(%s)", $1, $2 }')"
	[ -z "$wrong" ] || die "the package feeds offer packages for another architecture:${wrong}, this router is ${DISTRIB_ARCH}"
	# dnsmasq-full is staged and checked separately for a DNS replacement.
	opkg --noaction install $files > "$WORKDIR/opkg-simulate.log" 2>&1 || {
		cat "$WORKDIR/opkg-simulate.log" >&2
		die "opkg cannot satisfy the versioned Easy VLESS dependencies"
	}
	space_verdict "$res" "$own_kb" 2048
}

# space_verdict RESOLVED OWN_KB TMP_RESERVE_KB: compare the worst-case size of
# the resolved feed packages ("<package> <arch> <installed bytes> <download
# bytes>" lines) plus the Easy VLESS packages with the free space of the
# overlay, and the downloads with the free space of /tmp
space_verdict() {
	local res="$1" own_kb="$2" tmp_reserve="$3" n newkb dlkb need_kb margin_kb tmp_free fsnote=""
	n="$(echo "$res" | awk 'NF == 4 { n++ } END { print n + 0 }')"
	newkb="$(echo "$res" | awk 'NF == 4 { s += $3 } END { printf "%d", s / 1024 + 0.999 }')"
	dlkb="$(echo "$res" | awk 'NF == 4 { s += $4 } END { printf "%d", s / 1024 + 0.999 }')"
	[ "$n" = "0" ] || say "packages from the feeds (${DISTRIB_ARCH}) to install: $(echo "$res" | awk 'NF == 4 { printf "%s%s", sep, $1; sep = " " }')"
	need_kb=$((newkb + own_kb))
	case "$OVL_FS" in
		ubifs|jffs2)
			need_kb=$((need_kb * COMPRESSED_FS_PERCENT / 100))
			fsnote=" (${OVL_FS} compresses: ${COMPRESSED_FS_PERCENT}% of the uncompressed $((newkb + own_kb)) KB counted)" ;;
	esac
	need_kb=$((need_kb + SPACE_RESERVE_KB))
	margin_kb=$((OVL_FREE_KB - need_kb))
	say "free space on ${OVL_MNT}: $(mb "$OVL_FREE_KB") MB, required: $(mb "$need_kb") MB${fsnote} = ${n} new packages ($(mb "$newkb") MB installed) + Easy VLESS ($(mb "$own_kb") MB) + reserve $(mb "$SPACE_RESERVE_KB") MB; margin: $(mb "$margin_kb") MB"
	[ "$margin_kb" -ge 0 ] || die "not enough free space on ${OVL_MNT}: $(mb "$OVL_FREE_KB") MB free, $(mb "$need_kb") MB required (missing $(mb $((0 - margin_kb))) MB). Nothing was changed. Free space by removing unused packages, or use a router with more flash"
	set -- $(fs_space /tmp)
	tmp_free="${2:-}"
	if [ -n "$tmp_free" ]; then
		[ "$tmp_free" -ge $((dlkb + tmp_reserve)) ] || die "not enough free space in /tmp (RAM) for the downloads: $(mb "$tmp_free") MB free, $(mb $((dlkb + tmp_reserve))) MB required. Nothing was changed."
		say "free space in /tmp: $(mb "$tmp_free") MB, downloads: $(mb "$dlkb") MB - ok"
	fi
}

# check_space_apk: check_space for apk. "apk add --simulate" resolves the
# whole installation (the verified local files, dnsmasq-full
# and every dependency from the feeds of this router) without changing
# anything; the sizes of the new feed packages come from the signed indexes.
check_space_apk() {
	local files="" wants="" own_kb=0 p f sz names res wrong log="$WORKDIR/apk-simulate.log" err removal
	for p in $EV_PACKAGES; do
		f="$PKGDIR/$(pkg_file "$p")"
		files="$files $f"
		sz="$(apk_file_field "$f" installed-size)"
		[ -n "$sz" ] || die "cannot read the package data of $(basename "$f")"
		own_kb=$((own_kb + sz / 1024 + 1))
	done
	if [ "$NEED_DNSMASQ" = 1 ]; then
		wants="dnsmasq-full $DNSMASQ_CONSTRAINT"
	fi
	# shellcheck disable=SC2086
	if ! apk add --simulate $APK_OFFLINE $files $wants >"$log" 2>&1; then
		err="$(grep -v -e '^(' -e '^OK:' "$log" | head -n 8 | tr '\n' ' ')"
		die "apk cannot resolve the installation with the package feeds of this router (${DISTRIB_ARCH}): ${err:-see $log} - Easy VLESS cannot be installed on this architecture/firmware with the official feeds"
	fi
	removal="$(sed -n -E 's/^\([ 0-9]+\/[ 0-9]+\) (Purging|Removing) ([^ ]+) .*$/\3/p' "$log")"
	for p in $removal; do
		[ "$NEED_DNSMASQ" = 1 ] && [ "$p" = "$DNSMASQ_PKG" ] ||
			die "apk would remove $p; refusing to change unrelated packages"
	done
	if [ -n "$DNSMASQ_CONSTRAINT" ]; then
		printf '%s\n' "$removal" | grep -Fxq "$DNSMASQ_PKG" ||
			die "apk did not plan a replacement of $DNSMASQ_PKG by dnsmasq-full"
	fi
	for p in $(sed -n -E 's/^\([ 0-9]+\/[ 0-9]+\) (Upgrading|Downgrading|Replacing|Reinstalling) ([^ ]+) .*$/\3/p' "$log"); do
		case " $EV_PACKAGES " in *" $p "*) ;; *) die "apk would change installed dependency $p; update the router separately before installing Easy VLESS" ;; esac
	done
	# new or replaced packages from the feeds (the Easy VLESS packages are
	# counted from their own files)
	names="$(sed -n -E 's/^\([ 0-9]+\/[ 0-9]+\) Installing ([^ ]+) .*$/\1/p' "$log" \
		| grep -vx -e sing-box-lx -e easy-vless -e easy-vless-sing-box -e luci-app-easy-vless | sort -u)"
	res=""
	if [ -n "$names" ]; then
		# shellcheck disable=SC2086
		res="$(apk query --available --fields name,arch,installed-size,file-size $names 2>/dev/null | awk '
			$1 == "Name:" { n = $2; a = ""; i = 0; d = 0 }
			$1 == "Arch:" { a = $2 }
			$1 == "Installed-Size:" { i = $2 }
			$1 == "File-Size:" { d = $2 }
			/^$/ { if (n != "" && !(n in seen)) { seen[n] = 1; print n, a, i + 0, d + 0 } n = "" }
			END { if (n != "" && !(n in seen)) print n, a, i + 0, d + 0 }')"
		for p in $names; do
			echo "$res" | awk -v p="$p" '$1 == p { f = 1 } END { exit !f }' \
				|| die "apk would install $p, but its size is not in the package index - cannot check the free space"
		done
		# kernel modules and binaries only from the feeds of this architecture
		wrong="$(echo "$res" | awk -v a="$DISTRIB_ARCH" 'NF == 4 && $2 != a && $2 != "noarch" { printf " %s(%s)", $1, $2 }')"
		[ -z "$wrong" ] || die "the package feeds offer packages for another architecture:${wrong}, this router is ${DISTRIB_ARCH}. Nothing was changed."
	fi
	# apk keeps a copy of the indexes next to the downloads in /tmp
	space_verdict "$res" "$own_kb" 8192
}

# ---------------------------------------------------------------- 1. checks
say "Easy VLESS ${EV_TAG} (${EV_VERSION}) installer"

[ "$(id -u 2>/dev/null)" = "0" ] || die "run this script as root"
[ -r /etc/openwrt_release ] || die "/etc/openwrt_release not found - this is not OpenWrt"
. /etc/openwrt_release
say "OpenWrt: ${DISTRIB_RELEASE:-?} (${DISTRIB_REVISION:-?}), target ${DISTRIB_TARGET:-?}, architecture ${DISTRIB_ARCH:-?}"

[ -n "${DISTRIB_ARCH:-}" ] || die "DISTRIB_ARCH is empty in /etc/openwrt_release"
say "kernel: $(uname -m 2>/dev/null) $(uname -r 2>/dev/null), model: $(cat /tmp/sysinfo/model 2>/dev/null || echo unknown)"
case "$DISTRIB_ARCH" in
	x86_64|aarch64_cortex-a53) ;;
	*) die "no ${EV_TAG} core package for ${DISTRIB_ARCH}" ;;
esac
arch_matches_kernel ||
	die "architecture mismatch: /etc/openwrt_release says ${DISTRIB_ARCH}, the kernel runs on $(uname -m)"
# release series + package manager -> opkg/.ipk or apk/.apk (or stop)
detect_channel
if [ "$PM" = opkg ] && command -v opkg >/dev/null 2>&1; then
	opkg print-architecture | awk -v arch="$DISTRIB_ARCH" '$2 == arch { found = 1 } END { exit !found }' ||
		die "opkg does not accept the firmware package architecture ${DISTRIB_ARCH}"
fi

MISSING=""
for t in wget tar gzip sha256sum awk sed grep df flock pgrep uci mktemp; do
	command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
[ -z "$MISSING" ] || die "required tools missing:${MISSING}"

WORKDIR="$(mktemp -d /tmp/easy-vless-install.XXXXXX)" || die "cannot create a temporary directory in /tmp"
# apk options for every installation from the feeds: all downloads (to /tmp)
# are finished before the transaction changes anything
APK_DL="--cache-predownload"
if [ "$PM" = "apk" ]; then
	mkdir -p "$WORKDIR/apk-cache" || die "cannot create $WORKDIR/apk-cache"
	apk() {
		if [ "$OPT_CHECK" = 1 ]; then
			command apk --cache-dir "$WORKDIR/apk-cache" --logfile=no "$@"
		else
			command apk --cache-dir "$WORKDIR/apk-cache" "$@"
		fi
	}
else
	mkdir -p "$WORKDIR/opkg-lists" || die "cannot create temporary opkg lists directory"
	# An explicit lists_dir in /etc/opkg.conf overrides the CLI flag on
	# 24.10. Keep signed indexes in the transaction directory.
	awk '$1 != "lists_dir"' /etc/opkg.conf > "$WORKDIR/opkg.conf" ||
		die "cannot copy opkg configuration"
	printf 'lists_dir ext %s\n' "$WORKDIR/opkg-lists" >> "$WORKDIR/opkg.conf" ||
		die "cannot configure temporary opkg lists"
	opkg() { command opkg --conf "$WORKDIR/opkg.conf" "$@"; }
fi

check_system_requirements
if [ "$OPT_CHECK" = 0 ]; then
	umask 077
	mkdir -p /var/lock
	exec 8>>/var/lock/easy_vless_install.lock
	flock -xn 8 || die "another Easy VLESS installation is in progress"
fi

APK_OFFLINE=""
if [ "$OPT_OFFLINE" = 1 ]; then
	APK_OFFLINE="--network=no --repositories-file /dev/null"
else
	# Time synchronisation or installation of TLS prerequisites belongs to
	# provisioning the router, before this transactional installer.
	[ "$(now_epoch)" -ge "$(date -d "$EV_MIN_DATE" +%s 2>/dev/null || echo 0)" ] ||
		die "router clock is too far behind for TLS; synchronise it before installation"
	check_https
	[ "$HTTPS_BROKEN" = 0 ] || die "HTTPS prerequisites are missing; provision them first or use --offline"
	[ -n "$OPT_LOCAL" ] || check_dns "$(url_host "$EV_BASE_URL")"
	check_feeds
fi

command -v fw4 >/dev/null 2>&1 || die "fw4 (firewall4) not found - Easy VLESS needs OpenWrt's nftables firewall (fw4)"
command -v nft >/dev/null 2>&1 || die "nft not found - Easy VLESS needs nftables"

if pgrep -f /usr/share/passwall2/ >/dev/null 2>&1 || nft list table inet passwall2 >/dev/null 2>&1; then
	die "PassWall2 is running. Stop and disable it first: /etc/init.d/passwall2 stop; /etc/init.d/passwall2 disable"
fi

# ---------------------------------------------------------------- 2. feeds
[ "$OPT_OFFLINE" = 1 ] || pm_update

# An unowned binary would be replaced by the first installation. The
# standard sing-box packages own a different path and can coexist.
if [ -e /usr/bin/sing-box-lx ] || [ -L /usr/bin/sing-box-lx ]; then
	if [ "$PM" = apk ]; then
		owner="$(apk info --who-owns /usr/bin/sing-box-lx 2>/dev/null)"
		case "$owner" in *'owned by sing-box-lx-'*) ;; *) die "/usr/bin/sing-box-lx is not owned by the sing-box-lx package" ;; esac
	else
		opkg files sing-box-lx 2>/dev/null | grep -Fxq /usr/bin/sing-box-lx ||
			die "/usr/bin/sing-box-lx is not owned by the sing-box-lx package"
	fi
fi
custom_core="$(uci -q get 'easy_vless.@global_app[0].sing_box_file' || true)"
case "$custom_core" in
	""|/usr/bin/sing-box|/usr/bin/sing-box-lx) ;;
	*)
		custom_version="$(timeout 5 "$custom_core" version 2>/dev/null | sed -n '1s/^sing-box version //p')"
		[ "$custom_version" = "$LX_VERSION" ] || die "custom sing_box_file is incompatible; choose a compatible sing-box-lx binary or use the package default"
		;;
esac
for p in sing-box sing-box-tiny; do
	[ -z "$(installed_version "$p")" ] || say "$p remains installed for any existing consumers"
done

# ---------------------------------------------------------------- 4. dnsmasq
DNSMASQ_ACTION=""
NEED_DNSMASQ=0
DNSMASQ_CONSTRAINT=""
DNSMASQ_PKG=""
OLD_DNS_VERSION=""
OLD_IPK=""
if dnsmasq_has_nftset; then
	say "dnsmasq has nftset support - ok"
else
	NEED_DNSMASQ=1
	[ "$OPT_OFFLINE" = 0 ] || die "--offline requires an installed dnsmasq with nftset support"
	if [ "$PM" = "apk" ]; then
		for p in dnsmasq dnsmasq-dhcpv6 dnsmasq-full; do
			[ -n "$(installed_version "$p")" ] && { DNSMASQ_PKG="$p"; break; }
		done
	else
		DNSMASQ_PKG="$(opkg list-installed 2>/dev/null | awk '$1 ~ /^dnsmasq/ { print $1; exit }')"
	fi
	[ -z "$DNSMASQ_PKG" ] || OLD_DNS_VERSION="$(installed_version "$DNSMASQ_PKG")"
	if [ "$PM" = apk ]; then
		case "$DNSMASQ_PKG" in
			# Keep the generic requirement; dnsmasq-full provides it even
			# when it shares the old package's version.
			dnsmasq) DNSMASQ_CONSTRAINT=dnsmasq ;;
			dnsmasq-dhcpv6) DNSMASQ_CONSTRAINT="!$DNSMASQ_PKG=$OLD_DNS_VERSION" ;;
		esac
	fi
	[ -n "$(pkg_field dnsmasq-full Version)" ] || die "dnsmasq-full is not available in the package feeds - cannot provide nftset support"
	echo
	say "Easy VLESS needs dnsmasq-full (dnsmasq with nftset support)."
	say "Installed now: ${DNSMASQ_PKG:-no dnsmasq package}. Replacing it means:"
	say "  - dnsmasq-full and its dependencies are downloaded first (nothing is removed if that fails);"
	say "  - /etc/config/dhcp is backed up to /etc/config/dhcp.easy-vless.bak and kept;"
	say "  - ${DNSMASQ_PKG:-dnsmasq} is removed and dnsmasq-full installed from the downloaded file;"
	say "  - DHCP/DNS on this router stop for a few seconds while dnsmasq restarts;"
	say "  - if installing dnsmasq-full fails or the installer is interrupted, ${DNSMASQ_PKG:-dnsmasq} is reinstalled from its downloaded file."
	if [ "$OPT_CHECK" = "1" ]; then
		say "(--check: nothing is changed; run without --check to be asked, or with --replace-dnsmasq)"
	elif [ "$OPT_REPLACE_DNSMASQ" = "1" ] && [ "$OPT_YES" = "1" ]; then
		DNSMASQ_ACTION="replace"
	elif ask "Replace ${DNSMASQ_PKG:-dnsmasq} with dnsmasq-full now?"; then
		DNSMASQ_ACTION="replace"
	elif [ "$OPT_REPLACE_DNSMASQ" = "1" ] && [ ! -t 0 ]; then
		DNSMASQ_ACTION="replace"
	fi
	if [ "$OPT_CHECK" = "0" ] && [ "$DNSMASQ_ACTION" != "replace" ]; then
		die "dnsmasq-full is required and was not installed. Run again with --replace-dnsmasq (the steps above are shown before anything is changed)."
	fi
fi

# ---------------------------------------------------------------- 5. packages
# Every file is downloaded (or copied) and verified before anything is changed
# (also with --check: the release files and the free space are checked too).
PKGDIR="$WORKDIR/packages"
mkdir -p "$PKGDIR" || die "cannot create $PKGDIR"
if [ -n "$OPT_LOCAL" ]; then
	OPT_LOCAL="$(cd "$OPT_LOCAL" && pwd)" || die "cannot access --local directory"
	[ -d "$OPT_LOCAL" ] || die "--local: $OPT_LOCAL is not a directory"
	[ -f "$OPT_LOCAL/SHA256SUMS" ] || die "--local: SHA256SUMS not found in $OPT_LOCAL"
	cp "$OPT_LOCAL/SHA256SUMS" "$PKGDIR/SHA256SUMS" || die "--local: cannot copy SHA256SUMS"
	[ "$(sha256_of "$PKGDIR/SHA256SUMS")" = "$OPT_MANIFEST_SHA256" ] ||
		die "release manifest digest mismatch; nothing was installed"
	EXT=".ipk"; [ "$PM" = "apk" ] && EXT=".apk"
	for p in $EV_PACKAGES; do
		f="$(pkg_file "$p")"
		if [ ! -f "$OPT_LOCAL/$f" ]; then
			found=""
			for g in "$OPT_LOCAL"/*"$EXT"; do [ -f "$g" ] && found="$found $(basename "$g")"; done
			die "--local: $f not found in $OPT_LOCAL (this installer is for Easy VLESS ${EV_VERSION}, package manager ${PM}; ${EXT} files there:${found:- none})"
		fi
		cp "$OPT_LOCAL/$f" "$PKGDIR/$f" || die "--local: cannot stage $f"
	done
	say "Easy VLESS packages taken from $OPT_LOCAL"
else
	resolve_base_url
	say "downloading Easy VLESS ${EV_VERSION} from ${EV_BASE_URL}"
	fetch "${EV_BASE_URL}/SHA256SUMS" "$PKGDIR/SHA256SUMS" "SHA256SUMS of Easy VLESS ${EV_VERSION}"
	[ "$(sha256_of "$PKGDIR/SHA256SUMS")" = "$OPT_MANIFEST_SHA256" ] ||
		die "release manifest digest mismatch; nothing was installed"
	for p in $EV_PACKAGES; do
		f="$(pkg_file "$p")"
		fetch "${EV_BASE_URL}/${f}" "$PKGDIR/$f" "$f"
	done
fi
for p in $EV_PACKAGES; do
	f="$(pkg_file "$p")"
	# exactly one "<64 hex>  <file name>" line for this file
	want="$(awk -v f="$f" 'NF == 2 && $2 == f && $1 ~ /^[0-9a-f]+$/ && length($1) == 64 { print $1; n++ } END { if (n != 1) exit 1 }' "$PKGDIR/SHA256SUMS")" \
		|| die "${f} is not listed exactly once in SHA256SUMS - release files do not belong together"
	[ -s "$PKGDIR/$f" ] || die "$f is empty"
	[ "$(sha256_of "$PKGDIR/$f")" = "$want" ] || die "checksum mismatch for ${f} (SHA256SUMS: ${want}, file: $(sha256_of "$PKGDIR/$f")) - nothing was installed"
	# The package inside must be the one its file name promises.
	expected="$p $(pkg_version "$p") $(pkg_arch "$p")"
	if [ "$PM" = "apk" ]; then
		got="$(apk_file_field "$PKGDIR/$f" name) $(apk_file_field "$PKGDIR/$f" version) $(apk_file_field "$PKGDIR/$f" arch)"
		apk verify "$PKGDIR/$f" >/dev/null ||
			die "APK is not signed by a trusted key: $f"
		[ "$got" = "$expected" ] || die "Invalid metadata in $f: expected $expected, found ${got}"
	else
		got="$(ipk_control "$PKGDIR/$f" Package) $(ipk_control "$PKGDIR/$f" Version) $(ipk_control "$PKGDIR/$f" Architecture)"
		[ "$got" = "$expected" ] || die "Invalid metadata in $f: expected $expected, found ${got}"
	fi
done
say "Easy VLESS packages verified against SHA256SUMS"

# Digests from the published v1.2.0 release. Only these exact bytes may be
# used for legacy rollback, whether supplied locally or fetched over HTTPS.
legacy_digest() {
	case "$1" in
		easy-vless-sing-box_1.2.0-r1_all.ipk) echo 91d18df06b603cfb9ff69113d0bfe8a1b58f07a34d75e482ea7eb160848084d7 ;;
		easy-vless_1.2.0-r1_all.ipk) echo cfec5390488af6373058958e8fe6a613f352f1ebf70c07b13e4f6c2ea0c1ee66 ;;
		luci-app-easy-vless_1.2.0-r1_all.ipk) echo 716eafc8145571187e499c46bed4a6e9dfdbba41f9b900bebadaebfc1613dcd9 ;;
		easy-vless-1.2.0-r1.apk) echo 362663e61c3b542303e0614d6a7c9b7107d1519385bba18475401a96198b6cd4 ;;
		easy-vless-sing-box-1.2.0-r1.apk) echo 99392e47a6c165c420a03e4d7b491233f550c656740e4e0adac3d3c9f7dae743 ;;
		luci-app-easy-vless-1.2.0-r1.apk) echo e7c6f17a2589ff806146011a623b2a230a451a1031e88a39853b01017d2c8cc0 ;;
	esac
}

# Verify a rollback set before touching packages. For 1.2.0 this contains the
# three application packages; the old core remains installed at its own path.
prepare_rollback() {
	local p old f dir sum got base expected legacy
	mkdir -p "$WORKDIR/previous" "$WORKDIR/opkg-lists" || return 1
	for p in $EV_PACKAGES; do
		old="$(installed_version "$p")"
		if [ -z "$old" ]; then
			EV_ADDED="${EV_ADDED:+$EV_ADDED }$p"
			continue
		fi
		[ "$old" != "$(pkg_version "$p")" ] || continue
		case "$old" in *[!A-Za-z0-9_.+-]*) die "invalid installed version for $p" ;; esac
		dir="$WORKDIR/previous/$p"
		mkdir -p "$dir" || return 1
		if [ "$p" = sing-box-lx ]; then
			if [ "$PM" = apk ]; then f="$p-$old-$DISTRIB_ARCH.apk"; else f="${p}_${old}_${DISTRIB_ARCH}.ipk"; fi
		else
			f="$(pkg_file "$p" "$old")"
		fi
		legacy="$(legacy_digest "$f")"
		if [ -n "$OPT_ROLLBACK" ]; then
			cp "$OPT_ROLLBACK/$f" "$dir/" || return 1
		else
			[ "$OPT_OFFLINE" = 0 ] && [ -n "$legacy" ] ||
				die "provide authenticated previous $p $old with --rollback-dir"
			base="https://github.com/$EV_REPO/releases/download/v1.2.0"
			fetch "$base/$f" "$dir/$f" "$f"
		fi
		sum="$legacy"
		if [ -z "$sum" ]; then
			sum="$(awk -v f="$f" 'NF == 2 && $2 == f && $1 ~ /^[0-9a-f]+$/ && length($1) == 64 { print $1; n++ } END { if (n != 1) exit 1 }' "$OPT_ROLLBACK/SHA256SUMS")" || return 1
		fi
		[ "$(sha256_of "$dir/$f")" = "$sum" ] || return 1
		expected="$p $old $(pkg_arch "$p")"
		if [ "$PM" = apk ]; then
			got="$(apk_file_field "$dir/$f" name) $(apk_file_field "$dir/$f" version) $(apk_file_field "$dir/$f" arch)"
			# The published 1.2.0 APKs predate package signing.
			if [ -z "$legacy" ]; then
				apk verify "$dir/$f" >/dev/null || return 1
			fi
		else
			got="$(ipk_control "$dir/$f" Package) $(ipk_control "$dir/$f" Version) $(ipk_control "$dir/$f" Architecture)"
		fi
		[ "$got" = "$expected" ] || return 1
		if [ "$PM" = apk ] && [ -n "$legacy" ]; then
			EV_LEGACY_APKS="${EV_LEGACY_APKS:+$EV_LEGACY_APKS }$dir/$f"
		else
			EV_PREVIOUS_FILES="${EV_PREVIOUS_FILES:+$EV_PREVIOUS_FILES }$dir/$f"
		fi
	done
}

prepare_dnsmasq_apk() {
	local u
	mkdir -p "$WORKDIR/dnsmasq" || die "cannot create $WORKDIR/dnsmasq"
	cp -p /etc/apk/world "$WORKDIR/dnsmasq/world" || die "cannot save apk world before DNS replacement"
	if [ -n "$DNSMASQ_PKG" ]; then
		# rollback copy: the package and the signed index of its feed, so
		# that it can be reinstalled without DNS (official .apk files are
		# not signed one by one - the index signature covers them)
		if [ -n "$OPT_DNS_ROLLBACK" ]; then
			cp "$OPT_DNS_ROLLBACK/packages.adb" "$WORKDIR/dnsmasq/packages.adb" ||
				die "cannot stage the signed dnsmasq rollback index"
			apk fetch --network=no --repositories-file /dev/null \
				--repository "$OPT_DNS_ROLLBACK/packages.adb" -o "$WORKDIR/dnsmasq" "$DNSMASQ_PKG" ||
				die "dnsmasq rollback archive cannot be verified against its signed index"
		else
			u="$(official_feeds | awk '$1 == "base" { print $2; exit }')"
			[ -n "$u" ] || die "the base feed is not configured - cannot prepare a rollback copy of $DNSMASQ_PKG"
			fetch "$u" "$WORKDIR/dnsmasq/packages.adb" "signed dnsmasq rollback index"
			apk fetch --repositories-file /dev/null --repository "$u" -o "$WORKDIR/dnsmasq" "$DNSMASQ_PKG" >/dev/null ||
				die "exact dnsmasq rollback package unavailable; supply a signed archive with --dnsmasq-rollback-dir"
		fi
		apk verify "$WORKDIR/dnsmasq/packages.adb" >/dev/null ||
			die "dnsmasq rollback index signature verification failed"
		OLD_IPK="$(cd "$WORKDIR/dnsmasq" && ls "${DNSMASQ_PKG}"-[0-9]*.apk 2>/dev/null | head -n1)"
		[ -s "$WORKDIR/dnsmasq/$OLD_IPK" ] ||
			die "rollback copy of $DNSMASQ_PKG not found - nothing was changed"
		[ "$(apk_file_field "$WORKDIR/dnsmasq/$OLD_IPK" version)" = "$OLD_DNS_VERSION" ] ||
			die "exact dnsmasq rollback package unavailable; supply a signed archive with --dnsmasq-rollback-dir"
	fi
}

prepare_dnsmasq_ipk() {
	mkdir -p "$WORKDIR/dnsmasq" && cd "$WORKDIR/dnsmasq" || die "cannot create $WORKDIR/dnsmasq"
	opkg download dnsmasq-full >/dev/null || die "opkg download dnsmasq-full failed - nothing was changed"
	NEW_IPK="$(ls dnsmasq-full_*.ipk 2>/dev/null | head -n1)"
	[ -n "$NEW_IPK" ] || die "dnsmasq-full was not downloaded - nothing was changed"
	WANT_SUM="$(feed_sha256 dnsmasq-full "$NEW_IPK")"
	[ -n "$WANT_SUM" ] || die "the feed index has no SHA256sum for dnsmasq-full - refusing to install an unverified file"
	[ "$(sha256_of "$NEW_IPK")" = "$WANT_SUM" ] || die "checksum mismatch for $NEW_IPK - nothing was changed"
	if [ -n "$DNSMASQ_PKG" ]; then
		if [ -n "$OPT_DNS_ROLLBACK" ]; then
			rollback_index="$OPT_DNS_ROLLBACK/Packages"
			usign -V -q -P /etc/opkg/keys -m "$rollback_index" -x "$rollback_index.sig" ||
				die "dnsmasq rollback index signature verification failed"
			entry="$(awk -v p="$DNSMASQ_PKG" -v v="$OLD_DNS_VERSION" -v a="$DISTRIB_ARCH" '
				function emit() { if (p == name && v == ver && a == arch && file != "" && sum != "") { print file, sum; n++ } }
				/^Package: / { emit(); name=$2; file=sum=arch=ver="" }
				/^Version: / { ver=$2 }
				/^Architecture: / { arch=$2 }
				/^Filename: / { file=$2 }
				/^SHA256sum: / { sum=$2 }
				END { emit(); if (n != 1) exit 1 }' "$rollback_index")" ||
				die "exact dnsmasq rollback version missing from signed index"
			OLD_IPK="${entry%% *}"
			OLD_IPK="${OLD_IPK#./}"
			OLD_SUM="${entry#* }"
			case "$OLD_IPK" in ""|*/*|*[!A-Za-z0-9_+.-]*) die "invalid dnsmasq rollback file name" ;; esac
			cp "$OPT_DNS_ROLLBACK/$OLD_IPK" "$WORKDIR/dnsmasq/$OLD_IPK" ||
				die "cannot stage dnsmasq rollback archive"
		else
			opkg download "$DNSMASQ_PKG" >/dev/null || die "opkg download $DNSMASQ_PKG (rollback copy) failed"
			OLD_IPK="$(ls "${DNSMASQ_PKG}"_*.ipk 2>/dev/null | head -n1)"
			OLD_SUM="$(feed_sha256 "$DNSMASQ_PKG" "$OLD_IPK")"
		fi
		[ -n "$OLD_IPK" ] || die "rollback copy of $DNSMASQ_PKG not found - nothing was changed"
		[ "$(ipk_control "$WORKDIR/dnsmasq/$OLD_IPK" Version)" = "$OLD_DNS_VERSION" ] ||
			die "exact dnsmasq rollback package unavailable; supply a signed archive with --dnsmasq-rollback-dir"
		[ -n "$OLD_SUM" ] && [ "$(sha256_of "$OLD_IPK")" = "$OLD_SUM" ] || die "checksum of the rollback copy $OLD_IPK could not be verified - nothing was changed"
	fi
	cd "$WORKDIR" || die "cannot enter $WORKDIR"
}

check_space
prepare_rollback || die "cannot verify the rollback packages; nothing was installed"
if [ "$NEED_DNSMASQ" = 1 ]; then
	if [ "$PM" = apk ]; then prepare_dnsmasq_apk; else prepare_dnsmasq_ipk; fi
fi

if [ "$OPT_CHECK" = "1" ]; then
	say "check finished: no blocking problem found (nothing was changed)"
	[ "$NEED_DNSMASQ" = "1" ] && say "  the installer will ask to replace dnsmasq with dnsmasq-full (or use --replace-dnsmasq)"
	exit 0
fi

# ---------------------------------------------------------------- 4b. dnsmasq
replace_dnsmasq_apk() {
	cp -p /etc/config/dhcp /etc/config/dhcp.easy-vless.bak 2>/dev/null || die "cannot back up /etc/config/dhcp - nothing was changed"
	DNSMASQ_STAGE="removed"
	# fault injection for the rollback test (tests/ci/installer-scenarios.sh)
	[ "${EV_TEST_SIGNAL_AFTER_DNSMASQ_REMOVE:-0}" = "1" ] && kill -TERM $$
	# shellcheck disable=SC2086
	if [ "${EV_TEST_FAIL_DNSMASQ_INSTALL:-0}" = "1" ] || ! apk add $APK_DL dnsmasq-full $DNSMASQ_CONSTRAINT; then
		warn "installing dnsmasq-full failed"
		die "dnsmasq-full could not be installed; restoring ${DNSMASQ_PKG:-dnsmasq}"
	fi
	[ -z "$DNSMASQ_CONSTRAINT" ] || apk del --network=no "$DNSMASQ_PKG" ||
		die "cannot clear the temporary dnsmasq constraint"
	# keep the router's DHCP/DNS configuration exactly as it was
	cp -p /etc/config/dhcp.easy-vless.bak /etc/config/dhcp || die "cannot restore DHCP configuration"
	rm -f /etc/config/dhcp.apk-new
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || die "dnsmasq restart failed; restoring the previous DNS/DHCP configuration"
	dnsmasq_has_nftset || die "dnsmasq-full was installed but dnsmasq still reports no nftset support"
	say "dnsmasq-full installed (backup of the DHCP config: /etc/config/dhcp.easy-vless.bak)"
}
if [ "$DNSMASQ_ACTION" = "replace" ] && [ "$PM" = "apk" ]; then
	say "replacing ${DNSMASQ_PKG:-dnsmasq} with dnsmasq-full ..."
	replace_dnsmasq_apk
elif [ "$DNSMASQ_ACTION" = "replace" ]; then
	say "replacing ${DNSMASQ_PKG:-dnsmasq} with dnsmasq-full ..."
	DEPS="$(pkg_field dnsmasq-full Depends | tr ',' '\n' | sed 's/([^)]*)//g; s/^[[:space:]]*//; s/[[:space:]].*$//' | grep -v -e '^$' -e '^libc$')"
	if [ -n "$DEPS" ]; then
		# shellcheck disable=SC2086
		opkg install $DEPS || die "installing the dependencies of dnsmasq-full failed - dnsmasq was not changed"
	fi
	cp -p /etc/config/dhcp /etc/config/dhcp.easy-vless.bak 2>/dev/null || die "cannot back up /etc/config/dhcp - nothing was changed"
	if [ -n "$DNSMASQ_PKG" ]; then
		DNSMASQ_STAGE="removed"
		opkg remove "$DNSMASQ_PKG" || die "opkg remove $DNSMASQ_PKG failed"
		# fault injection for the rollback test (tests/ci/installer-tests.sh)
		[ "${EV_TEST_SIGNAL_AFTER_DNSMASQ_REMOVE:-0}" = "1" ] && kill -TERM $$
	fi
	if [ "${EV_TEST_FAIL_DNSMASQ_INSTALL:-0}" = "1" ] || ! opkg install "$WORKDIR/dnsmasq/$NEW_IPK"; then
		warn "installing dnsmasq-full failed"
		die "dnsmasq-full could not be installed; restoring ${DNSMASQ_PKG:-dnsmasq}"
	fi
	# keep the router's DHCP/DNS configuration exactly as it was
	cp -p /etc/config/dhcp.easy-vless.bak /etc/config/dhcp || die "cannot restore DHCP configuration"
	rm -f /etc/config/dhcp-opkg
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || die "dnsmasq restart failed; restoring the previous DNS/DHCP configuration"
	dnsmasq_has_nftset || die "dnsmasq-full was installed but dnsmasq still reports no nftset support"
	say "dnsmasq-full installed (backup of the DHCP config: /etc/config/dhcp.easy-vless.bak)"
	cd "$WORKDIR" || die "cannot enter $WORKDIR"
fi

# ---------------------------------------------------------------- 6. install
[ ! -f /etc/config/easy_vless ] ||
	cp -p /etc/config/easy_vless "$WORKDIR/easy_vless.config" || die "configuration backup failed"
EV_WAS_RUNNING=0
/etc/init.d/easy_vless enabled >/dev/null 2>&1 && EV_WAS_ENABLED=1
if [ -x /usr/share/easy_vless/app.sh ] &&
	[ "$(/usr/share/easy_vless/app.sh status | jsonfilter -e '@.running' 2>/dev/null)" = true ]; then
	EV_WAS_RUNNING=1
fi
OLD_EV="$(installed_version easy-vless)"
say "installing sing-box-lx, easy-vless, easy-vless-sing-box, luci-app-easy-vless ${EV_VERSION}${OLD_EV:+ (installed now: ${OLD_EV})} ..."
IPKS=""
for p in $EV_PACKAGES; do
	IPKS="$IPKS $PKGDIR/$(pkg_file "$p")"
done
PM_INSTALL="opkg install"
[ "$PM" = "apk" ] && { PM_INSTALL="apk add"; }
# fault injection for the partial installation test (tests/ci/installer-
# scenarios.sh): only the first package gets installed, then opkg "fails"
ev_install() {
	# shellcheck disable=SC2086
	set -- $IPKS
	[ "${EV_TEST_FAIL_EV_INSTALL:-0}" = 0 ] || set -- "$1" "$2"
	if [ "$PM" = apk ]; then
		if [ "$OPT_OFFLINE" = 1 ]; then
			apk add $APK_OFFLINE "$@" || return 1
		else
			apk add $APK_DL "$@" || return 1
		fi
	else
		opkg install "$@" || return 1
	fi
	[ "${EV_TEST_FAIL_EV_INSTALL:-0}" = 0 ]
}
EV_STAGE=active
ev_install || die "$PM_INSTALL failed; restoring the previous Easy VLESS installation"
for p in $EV_PACKAGES; do
	[ "$(installed_version "$p")" = "$(pkg_version "$p")" ] || die "$p was not installed in the expected version"
done
[ ! -f "$WORKDIR/easy_vless.config" ] ||
	cp -p "$WORKDIR/easy_vless.config" /etc/config/easy_vless || die "cannot restore Easy VLESS configuration"
[ -s /etc/config/easy_vless ] || die "/etc/config/easy_vless is missing after installation"
[ "$(singbox_version)" = "$LX_VERSION" ] || die "the installed sing-box-lx binary did not report $LX_VERSION"

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
/etc/init.d/rpcd restart >/dev/null 2>&1 || warn "rpcd restart failed - reload the web interface later"

# ---------------------------------------------------------------- 7. service
/etc/init.d/easy_vless enable || die "/etc/init.d/easy_vless enable failed"
ENABLED="$(uci -q get easy_vless.@global[0].enabled)"
if [ "$OPT_NO_START" = "1" ]; then
	say "--no-start: service not restarted"
elif [ "$ENABLED" = "1" ]; then
	say "Main switch is on - restarting Easy VLESS ..."
	/etc/init.d/easy_vless restart || die "service restart failed; see /tmp/log/easy_vless.log"
else
	say "Main switch is off (new installation): add a server in LuCI -> Services -> Easy VLESS, then switch Main on and use Save & Start."
fi

# ---------------------------------------------------------------- 8. status
echo
say "installed packages (${PM}):"
installed_list | sed 's/^/    /'
say "sing-box-lx: $(singbox_version || echo 'not found')"
if dnsmasq_has_nftset; then say "dnsmasq nftset support: yes"; else warn "dnsmasq nftset support: NO - Easy VLESS will refuse to start"; fi
if /etc/init.d/easy_vless enabled 2>/dev/null; then say "service: enabled at boot"; else warn "service: not enabled at boot"; fi
STATUS="$(ubus call luci.easy_vless status 2>/dev/null | sed -n 's/^[[:space:]]*"running": \(.*\),$/\1/p' | head -n1)"
say "running: ${STATUS:-unknown}"
EV_STAGE=""
DNSMASQ_STAGE=""
say "done. Web interface: LuCI -> Services -> Easy VLESS"
