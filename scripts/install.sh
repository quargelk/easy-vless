#!/bin/sh
# Easy VLESS installer for OpenWrt 24.10 (opkg, fw4/nftables), any target and
# architecture that the official OpenWrt feeds provide sing-box-tiny for.
# https://github.com/quargelk/easy-vless
#
# A plain, readable shell script: download it, read it, then run it as root.
#   wget -O /tmp/install.sh https://github.com/quargelk/easy-vless/releases/download/v0.7.1/install.sh
#   sh /tmp/install.sh --check          # only check the router, install nothing
#   sh /tmp/install.sh                  # install
#
# The Easy VLESS packages are "Architecture: all" (shell/Lua/JS only); every
# architecture-specific package (sing-box-tiny, dnsmasq-full, curl, kernel
# modules, ...) comes from the official feeds configured on the router for its
# own release, target and architecture (/etc/opkg/distfeeds.conf).
#
# What it does, in order (stops at the first error; nothing is changed before
# step 5 has downloaded and verified every file and checked the free space):
#   1. detects and checks the router: root, OpenWrt release, target and
#      architecture (/etc/openwrt_release against the running kernel), RAM
#      (>= 256 MB) and flash/storage size (>= 128 MB), required tools, system
#      time (HTTPS certificates cannot be verified with a clock that is
#      behind - a one-time NTP synchronisation is tried), TLS library and CA
#      certificates for HTTPS, DNS, opkg, the package feeds (release, target
#      and architecture of this router), fw4/nftables, PassWall2 not running;
#      when opkg itself is missing on an OpenWrt 24.10.x router, it can
#      bootstrap opkg from the official package archive of this release and
#      architecture (--bootstrap-opkg or an interactive "y"; see
#      bootstrap_opkg below);
#   2. opkg update (the feeds Easy VLESS needs must work; optional feeds such
#      as routing/telephony may fail with a warning);
#   3. sing-box: keeps an installed sing-box/sing-box-tiny >= 1.12.0, otherwise
#      installs sing-box-tiny from the official OpenWrt package feed of this
#      router (opkg selects the package for this router's architecture and
#      verifies the feed signature and package checksum);
#   4. dnsmasq-full (dnsmasq with nftset support, required by Easy VLESS):
#      only replaces the default dnsmasq after explicit confirmation
#      (--replace-dnsmasq or an interactive "y"), with a rollback package
#      downloaded first and a backup of /etc/config/dhcp; an error or an
#      interruption (Ctrl-C) during the replacement restores the old dnsmasq;
#   5. downloads the Easy VLESS packages of this release and verifies them
#      against the release SHA256SUMS (or uses --local DIR); resolves every
#      package that will be installed (with all dependencies, from the feeds
#      of this architecture) and checks the free space on the overlay and in
#      /tmp against their worst-case installed size - also with --check;
#   6. installs easy-vless, easy-vless-sing-box and luci-app-easy-vless
#      (existing /etc/config/easy_vless is kept; opkg treats it as a conffile);
#   7. enables the service; restarts it only when it is already switched on
#      (Main switch) - a fresh install is started from the web interface
#      after a server has been added;
#   8. prints a status summary.
#
# Downloads always use HTTPS with certificate verification (never
# --no-check-certificate). Optional packages (easy-vless-xray,
# easy-vless-geodata) are never installed by this script.

set -u

EV_VERSION="0.7.1-r1"
EV_TAG="v0.7.1"
EV_REPO="quargelk/easy-vless"
EV_BASE_URL="https://github.com/${EV_REPO}/releases/download/${EV_TAG}"
# Release date of this installer: a system clock before this date is certainly
# wrong, and TLS certificates cannot be verified with it.
EV_MIN_DATE="2026-09-28"
EV_PACKAGES="easy-vless easy-vless-sing-box luci-app-easy-vless"
SINGBOX_MIN="1.12.0"
SUPPORTED_RELEASE="24.10"
OPKG_ARCHIVE="https://archive.openwrt.org/releases"
OPKG_STATUS="/usr/lib/opkg/status"

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
OPT_REPLACE_DNSMASQ=0
OPT_YES=0
OPT_NO_START=0
OPT_FORCE=0
OPT_BOOTSTRAP_OPKG=0

WORKDIR=""
DNSMASQ_STAGE=""
HTTPS_BROKEN=0
HTTPS_URL=""
HTTPS_ERR=""
BOOT_LOCAL=""
BOOTSTRAPPED=""

say()  { echo "[easy-vless] $*"; }
warn() { echo "[easy-vless] WARNING: $*" >&2; }
die()  { echo "[easy-vless] ERROR: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Easy VLESS ${EV_VERSION} installer for OpenWrt ${SUPPORTED_RELEASE}.x (opkg, fw4/nftables)

Usage: sh install.sh [options]

  --check            only run the checks (router, RAM, flash, time, HTTPS,
                     opkg feeds, sing-box, dnsmasq, release files, free
                     space); install and change nothing (files are only
                     downloaded to a temporary directory in /tmp)
  --local DIR        install the Easy VLESS .ipk files and SHA256SUMS from DIR
                     instead of downloading them from GitHub
  --base-url URL     download the release files from URL (an https:// mirror
                     of ${EV_BASE_URL})
  --replace-dnsmasq  allow replacing dnsmasq with dnsmasq-full
  --yes, -y          answer "yes" to the dnsmasq question (implies
                     --replace-dnsmasq)
  --no-start         do not restart the service at the end
  --bootstrap-opkg   allow installing opkg itself when it is missing
                     (OpenWrt ${SUPPORTED_RELEASE}.x, from ${OPKG_ARCHIVE})
  --force            continue on an OpenWrt release other than ${SUPPORTED_RELEASE}.x,
                     on an architecture mismatch or unknown architecture,
                     with package feeds of another release/target/architecture,
                     or without an opkg package database (not tested; the
                     RAM, flash and free space requirements still apply)
  -h, --help         show this help

Optional packages (easy-vless-xray, easy-vless-geodata) are never installed
by this script.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--check) OPT_CHECK=1 ;;
		--local) [ $# -ge 2 ] || die "--local needs a directory"; OPT_LOCAL="$2"; shift ;;
		--base-url) [ $# -ge 2 ] || die "--base-url needs a URL"; EV_BASE_URL="${2%/}"; shift ;;
		--replace-dnsmasq) OPT_REPLACE_DNSMASQ=1 ;;
		--yes|-y) OPT_YES=1; OPT_REPLACE_DNSMASQ=1 ;;
		--no-start) OPT_NO_START=1 ;;
		--force) OPT_FORCE=1 ;;
		--bootstrap-opkg) OPT_BOOTSTRAP_OPKG=1 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1 (see --help)" ;;
	esac
	shift
done
case "$EV_BASE_URL" in
	https://?*) ;;
	*) die "--base-url must be an https:// URL (downloads are never made without TLS): $EV_BASE_URL" ;;
esac

# ---------------------------------------------------------------- helpers

# version_ge A B: true when version A >= B (numeric dot-separated parts)
version_ge() {
	awk -v a="$1" -v b="$2" 'BEGIN {
		na = split(a, x, "."); nb = split(b, y, ".");
		n = (na > nb) ? na : nb;
		for (i = 1; i <= n; i++) {
			xi = x[i] + 0; yi = y[i] + 0;
			if (xi > yi) exit 0;
			if (xi < yi) exit 1;
		}
		exit 0 }'
}

# pkg_field PACKAGE FIELD: a field of the package in the opkg feed index
pkg_field() { opkg info "$1" 2>/dev/null | sed -n "s/^$2: //p" | head -n1; }

# feed_sha256 PACKAGE FILE: SHA256 of FILE from the (signature-checked) feed
# index, via "opkg info" or, when that does not print it, the downloaded lists
feed_sha256() {
	local sum l
	sum="$(pkg_field "$1" SHA256sum)"
	if [ -z "$sum" ]; then
		for l in "$(opkg_lists_dir)"/*; do
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

installed_version() { opkg list-installed 2>/dev/null | awk -v p="$1" '$1 == p { print $3; exit }'; }

singbox_version() {
	command -v sing-box >/dev/null 2>&1 || return 1
	sing-box version 2>/dev/null | sed -n 's/^sing-box version \([0-9.]*\).*/\1/p' | head -n1
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

opkg_lists_dir() {
	local d
	d="$(awk '$1 == "lists_dir" { print $3; exit }' /etc/opkg.conf 2>/dev/null)"
	echo "${d:-/var/opkg-lists}"
}

now_epoch() { echo "${EV_TEST_NOW:-$(date +%s)}"; }

# ---------------------------------------------------------------- cleanup / rollback

# dnsmasq_rollback: reinstall the dnsmasq package that was removed for
# dnsmasq-full, from the copy downloaded before anything was changed
dnsmasq_rollback() {
	DNSMASQ_STAGE=""
	warn "restoring ${DNSMASQ_PKG:-dnsmasq} ..."
	if [ -n "${OLD_IPK:-}" ] && [ -f "$WORKDIR/dnsmasq/$OLD_IPK" ]; then
		opkg install "$WORKDIR/dnsmasq/$OLD_IPK" >&2 || warn "reinstalling $OLD_IPK failed - install ${DNSMASQ_PKG:-dnsmasq} manually: opkg install $WORKDIR/dnsmasq/$OLD_IPK"
	fi
	[ -f /etc/config/dhcp.easy-vless.bak ] && cp -p /etc/config/dhcp.easy-vless.bak /etc/config/dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
}

on_exit() {
	local rc=$?
	trap - EXIT INT TERM HUP
	# an error or interruption between "remove dnsmasq" and "dnsmasq-full
	# installed" must never leave the router without DNS/DHCP
	[ "$DNSMASQ_STAGE" = "removed" ] && dnsmasq_rollback
	[ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
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
}

sync_clock() {
	local servers args s pid i=0
	command -v ntpd >/dev/null 2>&1 || return 1
	servers="$(uci -q get system.ntp.server)"
	[ -n "$servers" ] || servers="0.openwrt.pool.ntp.org 1.openwrt.pool.ntp.org"
	args=""
	for s in $servers; do args="$args -p $s"; done
	say "trying a one-time NTP synchronisation (${servers}) ..."
	# shellcheck disable=SC2086
	ntpd -n -q $args >/dev/null 2>&1 &
	pid=$!
	while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	return 0
}

# check_clock: TLS certificates are only valid from their issue date; a
# router without a battery-backed clock starts with the build date of its
# firmware until NTP has synchronised the time, and every HTTPS request then
# fails with "SSL verify error: unknown error" (certificate not yet valid).
check_clock() {
	local min
	min="$(date -d "$EV_MIN_DATE" +%s 2>/dev/null)"
	[ -n "$min" ] || die "cannot parse EV_MIN_DATE=$EV_MIN_DATE with this date command"
	if [ "$(now_epoch)" -ge "$min" ]; then
		say "system time: $(date -u '+%Y-%m-%d %H:%M UTC') - ok"
		return 0
	fi
	warn "system time is $(date -u '+%Y-%m-%d %H:%M UTC'), before ${EV_MIN_DATE} (the release date of this installer): HTTPS certificates cannot be verified with this clock"
	sync_clock
	if [ "$(now_epoch)" -ge "$min" ]; then
		say "system time synchronised: $(date -u '+%Y-%m-%d %H:%M UTC')"
		return 0
	fi
	die "the system time is still wrong ($(date -u '+%Y-%m-%d %H:%M UTC')). Check the internet connection and DNS, then set the time with 'ntpd -n -q -p 0.openwrt.pool.ntp.org' (or 'date -s \"YYYY-MM-DD hh:mm:ss\"') and run the installer again"
}

# https_probe URL: one real HTTPS request with wget (uclient-fetch), the
# certificate verified as for every download. Returns 0 when it works,
# otherwise HTTPS_ERR holds the error text.
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

# local_index_ok: --local DIR has the base feed index of this router
# (Packages + Packages.sig), verified with the router's own OpenWrt keys
local_index_ok() {
	[ -n "$OPT_LOCAL" ] && [ -f "$OPT_LOCAL/Packages" ] && [ -f "$OPT_LOCAL/Packages.sig" ] || return 1
	command -v usign >/dev/null 2>&1 && any_exists /etc/opkg/keys/* \
		|| die "--local: $OPT_LOCAL/Packages cannot be verified: usign or the OpenWrt keys (/etc/opkg/keys) are missing"
	usign -V -q -P /etc/opkg/keys -m "$OPT_LOCAL/Packages" -x "$OPT_LOCAL/Packages.sig" \
		|| die "--local: the signature of $OPT_LOCAL/Packages is not valid for this router's OpenWrt keys - nothing installed"
	return 0
}

# local_pkg_verified FILE: true (LOCAL_PKG = package name) when FILE is
# listed in the verified $OPT_LOCAL/Packages; dies on a wrong architecture or
# checksum. Not for $(...): die must stop the installer, not a subshell.
local_pkg_verified() {
	local b name arch want
	LOCAL_PKG=""
	b="$(basename "$1")"
	name="$(awk -v fn="$b" '/^Package: /{ p = $2 } /^Filename: /{ if ($2 == fn) { print p; exit } }' "$OPT_LOCAL/Packages")"
	[ -n "$name" ] || return 1
	arch="$(awk -v p="$name" '/^Package: /{ q = $2 } /^Architecture: /{ if (q == p) { print $2; exit } }' "$OPT_LOCAL/Packages")"
	case "$arch" in "$DISTRIB_ARCH"|all) ;; *) die "--local: $b is built for '$arch', this router is $DISTRIB_ARCH" ;; esac
	want="$(awk -v p="$name" '/^Package: /{ q = $2 } /^SHA256sum: /{ if (q == p) { print $2; exit } }' "$OPT_LOCAL/Packages")"
	[ -n "$want" ] && [ "$(sha256_of "$1")" = "$want" ] || die "--local: checksum mismatch for $b (signed index $OPT_LOCAL/Packages) - nothing installed"
	LOCAL_PKG="$name"
}

# ensure_https: install the TLS backend / CA certificates when check_https
# found them missing. Without HTTPS nothing can be downloaded (there is no
# HTTP fallback), so they come from --local DIR: the base feed index
# (Packages, Packages.sig) and the packages, copied from a PC. The index
# signature is checked with the router's keys and every package against it.
ensure_https() {
	local f name list="" names="" lists hidden rc
	[ "${HTTPS_BROKEN:-0}" = "1" ] || return 0
	local_index_ok || die "HTTPS does not work on this router: $(explain_download_error "$HTTPS_URL" "$HTTPS_ERR"). Nothing can be downloaded without it (there is no HTTP fallback). On a PC, download https://downloads.openwrt.org/releases/${DISTRIB_RELEASE}/packages/${DISTRIB_ARCH}/base/Packages and Packages.sig plus the files of libustream-mbedtls* and ca-bundle listed in Packages, copy them into one directory on the router (scp -O) and run this installer with --local DIR (README section \"HTTPS на новом роутере\", HTTPS on a new router)"
	for f in "$OPT_LOCAL"/*.ipk; do
		[ -f "$f" ] || continue
		local_pkg_verified "$f" || continue
		name="$LOCAL_PKG"
		case "$name" in
			libustream-*|libmbedtls*|libwolfssl*|libopenssl*|ca-bundle|ca-certificates) list="$list $f"; names="$names $name" ;;
		esac
	done
	[ -n "$list" ] || die "HTTPS does not work ($(echo "$HTTPS_ERR" | tr '\n' ' ')) and $OPT_LOCAL has no TLS/CA package listed in its Packages index (libustream-mbedtls*, ca-bundle)"
	[ "$OPT_CHECK" = "1" ] && die "--check: HTTPS does not work; the installer would install${names} from $OPT_LOCAL (verified) - run it without --check"
	say "installing the HTTPS prerequisites from ${OPT_LOCAL} (index signature and SHA256 verified):${names}"
	# opkg prefers a feed entry of the same name and version over the local
	# file and would try to download it - over the HTTPS that does not work.
	# Hide the package lists (useless without HTTPS) during this install.
	lists="$(opkg_lists_dir)"
	hidden=""
	if [ -d "$lists" ]; then
		hidden="$WORKDIR/opkg-lists.hidden"
		mv "$lists" "$hidden" || die "cannot move $lists aside"
	fi
	# shellcheck disable=SC2086
	opkg install $list
	rc=$?
	if [ -n "$hidden" ]; then
		rm -rf "$lists"
		mv "$hidden" "$lists" || warn "could not restore $lists - run 'opkg update'"
	fi
	[ "$rc" = "0" ] || die "opkg install of${names} from $OPT_LOCAL failed"
	https_probe "$HTTPS_URL" || die "HTTPS still does not work after installing${names}: $(explain_download_error "$HTTPS_URL" "$HTTPS_ERR")"
	HTTPS_BROKEN=0
	say "HTTPS: ${HTTPS_URL} - ok (certificate verified) after installing${names}"
}

# check_dns HOST...: every host resolves (only when nslookup is available)
check_dns() {
	local h
	command -v nslookup >/dev/null 2>&1 || return 0
	for h in "$@"; do
		is_ip_literal "$h" && continue
		nslookup "$h" >/dev/null 2>&1 || die "the name $h cannot be resolved (DNS): check the internet connection and the DNS server of the router ('nslookup $h'). uclient-fetch reports this as \"Operation not permitted\""
	done
}

# ---------------------------------------------------------------- opkg bootstrap

# lib_present NAME: a library dependency like libubox20240329 is installed
# (/lib/libubox.so.20240329 or /usr/lib/...)
lib_present() {
	local base abi
	base="$(echo "$1" | sed -n 's/^\(lib[a-z-]*\)\([0-9]\{8\}\)$/\1/p')"
	abi="$(echo "$1" | sed -n 's/^lib[a-z-]*\([0-9]\{8\}\)$/\1/p')"
	[ -n "$base" ] || return 1
	any_exists "/lib/${base}.so.${abi}" "/usr/lib/${base}.so.${abi}"
}

# check_depends CONTROL: the runtime dependencies of a bootstrapped package
# are present (only the kinds used by opkg, usign and openwrt-keyring)
check_depends() {
	local d
	for d in $(sed -n 's/^Depends: //p' "$1" | tr ',' '\n' | sed 's/([^)]*)//g; s/^[[:space:]]*//; s/[[:space:]].*$//'); do
		case "$d" in
			libc|libpthread|librt) ;;
			uclient-fetch) command -v uclient-fetch >/dev/null 2>&1 || die "$(sed -n 's/^Package: //p' "$1") needs uclient-fetch, which is missing" ;;
			*) lib_present "$d" || die "$(sed -n 's/^Package: //p' "$1") needs $d, which is missing on this router - it cannot be bootstrapped safely" ;;
		esac
	done
}

# index_field PACKAGE FIELD: a field of PACKAGE in the downloaded base index
index_field() {
	awk -v p="$1" -v f="$2" '
		/^Package: / { pkg = $2 }
		index($0, f ": ") == 1 && pkg == p { print substr($0, length(f) + 3); exit }' "$BOOT_DIR/Packages"
}

# boot_get FILE DEST DESCRIPTION: a file of the base feed, from the archive
# over HTTPS or from --local DIR when HTTPS does not work yet
boot_get() {
	if [ -n "$BOOT_LOCAL" ]; then
		[ -f "$BOOT_LOCAL/$1" ] || die "--local: $1 ($3) not found in $BOOT_LOCAL"
		cp "$BOOT_LOCAL/$1" "$2" || die "cannot copy $BOOT_LOCAL/$1"
	else
		fetch "${BOOT_BASE}/$1" "$2" "$3"
	fi
}

# bootstrap_pkg NAME: install package NAME of this release and architecture
# from the official archive without opkg: exact file name and SHA256 from the
# base feed index, the package is checked (name, architecture, dependencies,
# paths inside data.tar.gz) before "tar -xzf data.tar.gz -C /". Existing
# configuration files (conffiles) are kept.
bootstrap_pkg() {
	local name="$1" file sum dir f
	dir="$BOOT_DIR/pkg-$name"
	file="$(index_field "$name" Filename)"
	sum="$(index_field "$name" SHA256sum)"
	[ -n "$file" ] && [ -n "$sum" ] || die "$name is not listed in ${BOOT_BASE}/Packages"
	echo "$file" | grep -qE "^${name}_[A-Za-z0-9.~+_-]+_(${DISTRIB_ARCH}|all)\.ipk\$" \
		|| die "unexpected file name '$file' for $name ($DISTRIB_ARCH) in ${BOOT_BASE}/Packages"
	echo "$sum" | grep -qE '^[0-9a-f]{64}$' || die "invalid SHA256sum for $name in ${BOOT_BASE}/Packages"
	mkdir -p "$dir" || die "cannot create $dir"
	boot_get "$file" "$dir/$file" "$name package"
	[ "$(sha256_of "$dir/$file")" = "$sum" ] || die "checksum mismatch for $file - nothing was installed"
	tar -xzf "$dir/$file" -C "$dir" || die "cannot unpack $file"
	for f in control.tar.gz data.tar.gz; do [ -f "$dir/$f" ] || die "$file has no $f"; done
	mkdir -p "$dir/control" && tar -xzf "$dir/control.tar.gz" -C "$dir/control" || die "cannot unpack the control data of $file"
	grep -qx "Package: $name" "$dir/control/control" || die "$file is not the package $name"
	case "$(sed -n 's/^Architecture: //p' "$dir/control/control")" in
		"$DISTRIB_ARCH"|all) ;;
		*) die "$file is not built for $DISTRIB_ARCH" ;;
	esac
	check_depends "$dir/control/control"
	# data.tar.gz is extracted to /: every entry must be a plain relative path
	tar -tzf "$dir/data.tar.gz" >"$dir/files" || die "cannot list $file"
	if grep -vE '^\./([A-Za-z0-9._~+-]+/)*[A-Za-z0-9._~+-]*$' "$dir/files" | grep -q . \
		|| grep -qE '(^|/)\.\.(/|$)' "$dir/files"; then
		die "$file contains unexpected paths - not installed"
	fi
	# keep existing conffiles (e.g. a customised /etc/opkg.conf)
	mkdir -p "$dir/keep"
	for f in $(cat "$dir/control/conffiles" 2>/dev/null); do
		[ -f "$f" ] && mkdir -p "$dir/keep$(dirname "$f")" && cp -p "$f" "$dir/keep$f"
	done
	tar -xzf "$dir/data.tar.gz" -C / || die "cannot extract $file to /"
	for f in $(cat "$dir/control/conffiles" 2>/dev/null); do
		[ -f "$dir/keep$f" ] && cp -p "$dir/keep$f" "$f"
	done
	BOOTSTRAPPED="$BOOTSTRAPPED $name"
	say "$name $(sed -n 's/^Version: //p' "$dir/control/control") installed from ${BOOT_BASE}/${file} (SHA256 verified)"
}

# bootstrap_opkg: install the opkg package of this OpenWrt release and
# architecture from the official package archive (and usign/openwrt-keyring
# when the package signature keys are missing). The package file names and
# SHA256 come from the "base" feed index of exactly this release/architecture;
# the index signature is verified with usign when usign and the OpenWrt keys
# are present. Nothing is guessed for other releases or architectures.
bootstrap_opkg() {
	local sig_ok=0
	BOOT_BASE="${OPKG_ARCHIVE}/${DISTRIB_RELEASE}/packages/${DISTRIB_ARCH}/base"
	BOOT_LOCAL=""
	BOOT_DIR="$WORKDIR/opkg-bootstrap"
	mkdir -p "$BOOT_DIR" || die "cannot create $BOOT_DIR"
	# refuse before changing anything when opkg could not work afterwards
	[ -s /etc/opkg/distfeeds.conf ] || die "/etc/opkg/distfeeds.conf is missing: opkg would have no package feeds - configure them first"
	if [ ! -s "$OPKG_STATUS" ]; then
		[ "$OPT_FORCE" = "1" ] || die "the opkg package database ($OPKG_STATUS) is missing: opkg would treat every installed package as missing and reinstall base packages. Use --force only if you know this is intended"
		warn "$OPKG_STATUS is missing - continuing because of --force"
	fi
	if [ "${HTTPS_BROKEN:-0}" = "1" ]; then
		# no HTTPS: the same files from --local DIR, index verified with the
		# router's own keys (local_index_ok dies when that is impossible)
		local_index_ok || die "opkg is missing and HTTPS does not work ($(echo "$HTTPS_ERR" | tr '\n' ' ')). Copy Packages, Packages.sig and the opkg package of ${BOOT_BASE}/ (plus libustream-mbedtls* and ca-bundle) from a PC into one directory and run with --local DIR --bootstrap-opkg"
		BOOT_LOCAL="$OPT_LOCAL"
		BOOT_BASE="$OPT_LOCAL"
	fi
	say "bootstrapping opkg from ${BOOT_BASE}"
	boot_get Packages "$BOOT_DIR/Packages" "package index of ${DISTRIB_RELEASE}/${DISTRIB_ARCH}/base"
	boot_get Packages.sig "$BOOT_DIR/Packages.sig" "package index signature"
	if command -v usign >/dev/null 2>&1 && any_exists /etc/opkg/keys/*; then
		usign -V -q -P /etc/opkg/keys -m "$BOOT_DIR/Packages" -x "$BOOT_DIR/Packages.sig" \
			|| die "signature check of ${BOOT_BASE}/Packages failed - nothing was installed"
		sig_ok=1
		say "feed index signature verified"
	else
		warn "usign or /etc/opkg/keys missing: the feed index is trusted through HTTPS only; the keys are installed from it and the signature is checked afterwards"
	fi
	bootstrap_pkg opkg
	if grep -qs '^option check_signature' /etc/opkg.conf; then
		command -v usign >/dev/null 2>&1 || bootstrap_pkg usign
		any_exists /etc/opkg/keys/* || bootstrap_pkg openwrt-keyring
		if [ "$sig_ok" = "0" ]; then
			usign -V -q -P /etc/opkg/keys -m "$BOOT_DIR/Packages" -x "$BOOT_DIR/Packages.sig" \
				|| die "the installed OpenWrt keys do not verify ${BOOT_BASE}/Packages.sig - do not use this opkg"
			say "feed index signature verified with the installed keys"
		fi
	fi
	command -v opkg >/dev/null 2>&1 || die "opkg bootstrap finished but opkg is still not found"
	opkg print-architecture 2>/dev/null | grep -q " ${DISTRIB_ARCH} " \
		|| die "the bootstrapped opkg does not work for ${DISTRIB_ARCH} ('opkg print-architecture')"
	say "opkg installed: $(opkg --version 2>/dev/null | head -n1)"
}

# register_bootstrapped: record the bootstrapped packages in the opkg
# database (same versions, from the now working feeds)
register_bootstrapped() {
	local p missing=""
	[ -n "$BOOTSTRAPPED" ] || return 0
	for p in $BOOTSTRAPPED; do [ -n "$(installed_version "$p")" ] || missing="$missing $p"; done
	[ -n "$missing" ] || return 0
	say "registering the bootstrapped packages in the opkg database:${missing}"
	# shellcheck disable=SC2086
	opkg install $missing >/tmp/easy-vless-opkg-register.log 2>&1 \
		|| warn "could not register${missing} (see /tmp/easy-vless-opkg-register.log); opkg works, run 'opkg install${missing}' later"
}

# ---------------------------------------------------------------- opkg update

# opkg_update: the feeds Easy VLESS needs (core/kmods/base/packages/luci)
# must be available; other feeds (routing, telephony, custom) are optional
opkg_update() {
	local log=/tmp/easy-vless-opkg-update.log lists feeds name url bad="" soft="" text
	lists="$(opkg_lists_dir)"
	feeds="$WORKDIR/feeds"
	cat /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf 2>/dev/null | awk '$1 ~ /^src/ && NF >= 3 { print $2, $3 }' >"$feeds"
	[ -s "$feeds" ] || die "no package feeds configured in /etc/opkg/distfeeds.conf"
	# stale lists from an earlier run must not hide a failed download
	while read -r name url; do rm -f "$lists/$name" "$lists/$name.sig"; done <"$feeds"
	say "opkg update ..."
	opkg update >"$log" 2>&1
	while read -r name url; do
		[ -s "$lists/$name" ] && continue
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
		die "$(explain_download_error "$(awk -v n="$1" '$1 == n { print $2; exit }' "$feeds")" "$text") (full log: $log)"
	fi
	[ -z "$soft" ] || warn "optional package feeds not available:${soft} (not needed by Easy VLESS; see $log)"
	grep -qs '^option check_signature' /etc/opkg.conf || warn "opkg signature checking (option check_signature) is not enabled in /etc/opkg.conf"
}

# check_feeds: the official package feeds in /etc/opkg/distfeeds.conf must be
# the ones of this router (release, target, architecture): feeds of another
# architecture give binaries for another CPU, of another target or release
# kernel modules that do not load (typical after a sysupgrade that kept an
# old distfeeds.conf, or a file copied from another router). Feeds with other
# URLs (mirrors with another layout, custom feeds) are not judged here; the
# dependency resolution in check_space verifies what they offer.
check_feeds() {
	local name url rel rest bad=""
	[ -s /etc/opkg/distfeeds.conf ] || die "/etc/opkg/distfeeds.conf is missing or empty - configure the official package feeds of OpenWrt ${DISTRIB_RELEASE} first"
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
$(awk '$1 ~ /^src/ && NF >= 3 { print $2, $3 }' /etc/opkg/distfeeds.conf)
EOF
	if [ -n "$bad" ]; then
		echo "[easy-vless] package feeds in /etc/opkg/distfeeds.conf that do not belong to this router:${bad}" >&2
		[ "$OPT_FORCE" = "1" ] || die "the package feeds are not the ones of OpenWrt ${DISTRIB_RELEASE} ${DISTRIB_TARGET} ${DISTRIB_ARCH} - packages for another CPU/kernel would be installed. Restore the original /etc/opkg/distfeeds.conf of this firmware (or use --force)"
		warn "package feeds of another release/target/architecture - continuing because of --force"
	fi
	say "package feeds: OpenWrt ${DISTRIB_RELEASE}, target ${DISTRIB_TARGET}, architecture ${DISTRIB_ARCH} - ok"
}

# ---------------------------------------------------------------- free space

# lists_stream: the downloaded package indexes of all feeds
lists_stream() {
	local l
	for l in "$(opkg_lists_dir)"/*; do
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
	{ cat "$OPKG_STATUS" 2>/dev/null; echo; echo "@@LISTS@@"; lists_stream; } | awk -v want="$*" '
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

# check_space: resolve everything that this run installs (sing-box-tiny,
# dnsmasq-full, the Easy VLESS packages and all their dependencies from the
# feeds of this router) and compare the worst-case installed size with the
# free space of the overlay; the downloads go to /tmp (RAM).
check_space() {
	local wants="" own_kb=0 p f dep sz res newkb dlkb n missing wrong need_kb margin_kb tmp_free fsnote=""
	for p in $EV_PACKAGES; do
		f="$PKGDIR/${p}_${EV_VERSION}_all.ipk"
		sz="$(ipk_control "$f" Installed-Size)"
		dep="$(ipk_control "$f" Depends)"
		[ -n "$sz" ] || die "cannot read the control data of $(basename "$f")"
		own_kb=$((own_kb + sz / 1024 + 1))
		wants="$wants $(echo "$dep" | sed 's/ //g; s/,/ /g')"
	done
	# the packages Easy VLESS itself provides are not taken from the feeds
	wants="$(for p in $wants; do case "$p" in easy-vless|easy-vless-sing-box|luci-app-easy-vless) ;; *) echo "$p" ;; esac; done)"
	[ "$SB_ACTION" = "install" ] && wants="sing-box-tiny $wants"
	# dnsmasq-full: installed in this run (or, with --check, proposed)
	[ "$NEED_DNSMASQ" = "1" ] && wants="$wants dnsmasq-full"
	# shellcheck disable=SC2086
	res="$(resolve_new $wants)"
	missing="$(echo "$res" | awk '$1 == "MISSING" { printf " %s", $2 }')"
	[ -z "$missing" ] || die "dependencies not available in the package feeds of this router (${DISTRIB_ARCH}):${missing} - Easy VLESS cannot be installed on this architecture/firmware with the official feeds"
	wrong="$(echo "$res" | awk -v a="$DISTRIB_ARCH" 'NF == 4 && $2 != a && $2 != "all" && $2 != "noarch" { printf " %s(%s)", $1, $2 }')"
	[ -z "$wrong" ] || die "the package feeds offer packages for another architecture:${wrong}, this router is ${DISTRIB_ARCH}"
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
		[ "$tmp_free" -ge $((dlkb + 2048)) ] || die "not enough free space in /tmp (RAM) for the downloads: $(mb "$tmp_free") MB free, $(mb $((dlkb + 2048))) MB required. Nothing was changed."
		say "free space in /tmp: $(mb "$tmp_free") MB, downloads: $(mb "$dlkb") MB - ok"
	fi
}

# ---------------------------------------------------------------- 1. checks
say "Easy VLESS ${EV_VERSION} installer"

[ "$(id -u 2>/dev/null)" = "0" ] || die "run this script as root"
[ -r /etc/openwrt_release ] || die "/etc/openwrt_release not found - this is not OpenWrt"
. /etc/openwrt_release
say "OpenWrt: ${DISTRIB_RELEASE:-?} (${DISTRIB_REVISION:-?}), target ${DISTRIB_TARGET:-?}, architecture ${DISTRIB_ARCH:-?}"

case "${DISTRIB_RELEASE:-}" in
	${SUPPORTED_RELEASE}.*) ;;
	*)
		[ "$OPT_FORCE" = "1" ] || die "OpenWrt ${DISTRIB_RELEASE:-unknown} is not supported by this installer (tested: ${SUPPORTED_RELEASE}.x). Use --force to try anyway."
		warn "OpenWrt ${DISTRIB_RELEASE:-unknown} is not a tested release - continuing because of --force"
		;;
esac
[ -n "${DISTRIB_ARCH:-}" ] || die "DISTRIB_ARCH is empty in /etc/openwrt_release"
say "kernel: $(uname -m 2>/dev/null) $(uname -r 2>/dev/null), model: $(cat /tmp/sysinfo/model 2>/dev/null || echo unknown)"
if [ -z "$(arch_family "$DISTRIB_ARCH")" ]; then
	[ "$OPT_FORCE" = "1" ] || die "architecture ${DISTRIB_ARCH} is not supported by this installer. Use --force to try anyway (sing-box-tiny must exist in the official feed of this architecture)."
	warn "unknown architecture ${DISTRIB_ARCH} - continuing because of --force"
elif ! arch_matches_kernel; then
	[ "$OPT_FORCE" = "1" ] || die "architecture mismatch: /etc/openwrt_release says ${DISTRIB_ARCH}, the kernel runs on $(uname -m). Use --force to continue anyway."
	warn "architecture mismatch (${DISTRIB_ARCH} / $(uname -m)) - continuing because of --force"
fi

MISSING=""
for t in wget tar gzip sha256sum awk sed grep df pgrep uci mktemp; do
	command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
[ -z "$MISSING" ] || die "required tools missing:${MISSING}"

WORKDIR="$(mktemp -d /tmp/easy-vless-install.XXXXXX)" || die "cannot create a temporary directory in /tmp"

check_system_requirements

check_clock
check_https
if [ -z "$OPT_LOCAL" ] && [ "${HTTPS_BROKEN:-0}" = "0" ]; then
	check_dns "$(url_host "$EV_BASE_URL")"
fi
check_feeds

if ! command -v opkg >/dev/null 2>&1; then
	command -v apk >/dev/null 2>&1 && die "this OpenWrt uses apk instead of opkg - not supported by Easy VLESS ${EV_VERSION} (OpenWrt ${SUPPORTED_RELEASE}.x with opkg is required)"
	case "${DISTRIB_RELEASE:-}" in
		${SUPPORTED_RELEASE}.*) ;;
		*) die "opkg not found, and bootstrapping it is only supported on OpenWrt ${SUPPORTED_RELEASE}.x" ;;
	esac
	say "opkg is not installed. It can be installed from ${OPKG_ARCHIVE}/${DISTRIB_RELEASE}/packages/${DISTRIB_ARCH}/base (package 'opkg' of this release and architecture)."
	[ "$OPT_CHECK" = "1" ] && die "--check: opkg is missing - the installer can bootstrap it (run without --check and confirm, or add --bootstrap-opkg); the remaining checks need opkg"
	if [ "$OPT_BOOTSTRAP_OPKG" = "1" ] || ask "Install opkg now?"; then
		[ "${HTTPS_BROKEN:-0}" = "1" ] || check_dns "$(url_host "$OPKG_ARCHIVE")"
		bootstrap_opkg
	else
		die "opkg is required. Run again with --bootstrap-opkg."
	fi
fi

ensure_https

command -v fw4 >/dev/null 2>&1 || die "fw4 (firewall4) not found - Easy VLESS needs OpenWrt's nftables firewall (fw4)"
command -v nft >/dev/null 2>&1 || die "nft not found - Easy VLESS needs nftables"

if pgrep -f /usr/share/passwall2/ >/dev/null 2>&1 || nft list table inet passwall2 >/dev/null 2>&1; then
	die "PassWall2 is running. Stop and disable it first: /etc/init.d/passwall2 stop; /etc/init.d/passwall2 disable"
fi

# ---------------------------------------------------------------- 2. feeds
opkg_update
register_bootstrapped

# ---------------------------------------------------------------- 3. sing-box
SB_ACTION=""
SB_VER="$(singbox_version || true)"
if [ -n "$SB_VER" ]; then
	version_ge "$SB_VER" "$SINGBOX_MIN" || die "installed sing-box ${SB_VER} is older than ${SINGBOX_MIN}. Upgrade it (opkg upgrade sing-box or sing-box-tiny) and run this script again."
	say "sing-box ${SB_VER} is already installed - kept"
else
	for p in sing-box sing-box-tiny; do
		[ -n "$(installed_version "$p")" ] && die "package $p is installed but the sing-box binary does not work - fix or remove it first"
	done
	SB_FEED_VER="$(pkg_field sing-box-tiny Version)"
	[ -n "$SB_FEED_VER" ] || die "sing-box-tiny is not available in the package feeds of this router (${DISTRIB_ARCH}). Install sing-box >= ${SINGBOX_MIN} manually (opkg install sing-box-tiny or sing-box) and run this script again."
	SB_FEED_ARCH="$(pkg_field sing-box-tiny Architecture)"
	case "$SB_FEED_ARCH" in
		"$DISTRIB_ARCH"|all) ;;
		*) die "sing-box-tiny in the feed is built for '${SB_FEED_ARCH}', this router is '${DISTRIB_ARCH}'" ;;
	esac
	version_ge "${SB_FEED_VER%%-*}" "$SINGBOX_MIN" || die "the feed offers sing-box-tiny ${SB_FEED_VER}, Easy VLESS needs >= ${SINGBOX_MIN}"
	say "sing-box-tiny ${SB_FEED_VER} (${SB_FEED_ARCH}) found in the official feed"
	SB_ACTION="install"
fi

# ---------------------------------------------------------------- 4. dnsmasq
DNSMASQ_ACTION=""
NEED_DNSMASQ=0
DNSMASQ_PKG=""
OLD_IPK=""
if dnsmasq_has_nftset; then
	say "dnsmasq has nftset support - ok"
else
	NEED_DNSMASQ=1
	DNSMASQ_PKG="$(opkg list-installed 2>/dev/null | awk '$1 ~ /^dnsmasq/ { print $1; exit }')"
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
	[ -d "$OPT_LOCAL" ] || die "--local: $OPT_LOCAL is not a directory"
	[ -f "$OPT_LOCAL/SHA256SUMS" ] || die "--local: SHA256SUMS not found in $OPT_LOCAL"
	cp "$OPT_LOCAL/SHA256SUMS" "$PKGDIR/SHA256SUMS" || die "--local: cannot copy SHA256SUMS"
	for p in $EV_PACKAGES; do
		f="${p}_${EV_VERSION}_all.ipk"
		if [ ! -f "$OPT_LOCAL/$f" ]; then
			found=""
			for g in "$OPT_LOCAL"/*.ipk; do [ -f "$g" ] && found="$found $(basename "$g")"; done
			die "--local: $f not found in $OPT_LOCAL (this installer is for Easy VLESS ${EV_VERSION}; .ipk files there:${found:- none})"
		fi
		cp "$OPT_LOCAL/$f" "$PKGDIR/$f" || die "--local: cannot copy $f"
	done
	say "Easy VLESS packages taken from $OPT_LOCAL"
else
	say "downloading Easy VLESS ${EV_VERSION} from ${EV_BASE_URL}"
	fetch "${EV_BASE_URL}/SHA256SUMS" "$PKGDIR/SHA256SUMS" "SHA256SUMS of Easy VLESS ${EV_VERSION}"
	for p in $EV_PACKAGES; do
		f="${p}_${EV_VERSION}_all.ipk"
		fetch "${EV_BASE_URL}/${f}" "$PKGDIR/$f" "$f"
	done
fi
for p in $EV_PACKAGES; do
	f="${p}_${EV_VERSION}_all.ipk"
	# exactly one "<64 hex>  <file name>" line for this file
	want="$(awk -v f="$f" 'NF == 2 && $2 == f && $1 ~ /^[0-9a-f]+$/ && length($1) == 64 { print $1; n++ } END { if (n != 1) exit 1 }' "$PKGDIR/SHA256SUMS")" \
		|| die "${f} is not listed exactly once in SHA256SUMS - release files do not belong together"
	[ -s "$PKGDIR/$f" ] || die "$f is empty"
	[ "$(sha256_of "$PKGDIR/$f")" = "$want" ] || die "checksum mismatch for ${f} (SHA256SUMS: ${want}, file: $(sha256_of "$PKGDIR/$f")) - nothing was installed"
done
say "Easy VLESS packages verified against SHA256SUMS"

check_space

if [ "$OPT_CHECK" = "1" ]; then
	say "check finished: no blocking problem found (nothing was changed)"
	[ "$SB_ACTION" = "install" ] && say "  the installer will install sing-box-tiny from the official feed"
	[ "$NEED_DNSMASQ" = "1" ] && say "  the installer will ask to replace dnsmasq with dnsmasq-full (or use --replace-dnsmasq)"
	exit 0
fi

# ---------------------------------------------------------------- 3b. sing-box
if [ "$SB_ACTION" = "install" ]; then
	say "installing sing-box-tiny from the official feed ..."
	opkg install sing-box-tiny || die "opkg install sing-box-tiny failed"
	SB_VER="$(singbox_version || true)"
	[ -n "$SB_VER" ] || die "sing-box-tiny was installed but 'sing-box version' does not work"
	say "sing-box ${SB_VER} installed"
fi

# ---------------------------------------------------------------- 4b. dnsmasq
if [ "$DNSMASQ_ACTION" = "replace" ]; then
	say "replacing ${DNSMASQ_PKG:-dnsmasq} with dnsmasq-full ..."
	mkdir -p "$WORKDIR/dnsmasq" && cd "$WORKDIR/dnsmasq" || die "cannot create $WORKDIR/dnsmasq"
	opkg download dnsmasq-full >/dev/null || die "opkg download dnsmasq-full failed - nothing was changed"
	NEW_IPK="$(ls dnsmasq-full_*.ipk 2>/dev/null | head -n1)"
	[ -n "$NEW_IPK" ] || die "dnsmasq-full was not downloaded - nothing was changed"
	WANT_SUM="$(feed_sha256 dnsmasq-full "$NEW_IPK")"
	[ -n "$WANT_SUM" ] || die "the feed index has no SHA256sum for dnsmasq-full - refusing to install an unverified file"
	[ "$(sha256_of "$NEW_IPK")" = "$WANT_SUM" ] || die "checksum mismatch for $NEW_IPK - nothing was changed"
	if [ -n "$DNSMASQ_PKG" ]; then
		opkg download "$DNSMASQ_PKG" >/dev/null || die "opkg download $DNSMASQ_PKG (rollback copy) failed - nothing was changed"
		OLD_IPK="$(ls "${DNSMASQ_PKG}"_*.ipk 2>/dev/null | head -n1)"
		[ -n "$OLD_IPK" ] || die "rollback copy of $DNSMASQ_PKG not found - nothing was changed"
		OLD_SUM="$(feed_sha256 "$DNSMASQ_PKG" "$OLD_IPK")"
		[ -n "$OLD_SUM" ] && [ "$(sha256_of "$OLD_IPK")" = "$OLD_SUM" ] || die "checksum of the rollback copy $OLD_IPK could not be verified - nothing was changed"
	fi
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
	if [ "${EV_TEST_FAIL_DNSMASQ_INSTALL:-0}" = "1" ] || ! opkg install "./$NEW_IPK"; then
		warn "installing dnsmasq-full failed"
		[ -n "$DNSMASQ_PKG" ] && dnsmasq_rollback
		die "dnsmasq-full could not be installed; ${DNSMASQ_PKG:-dnsmasq} was restored"
	fi
	DNSMASQ_STAGE=""
	# keep the router's DHCP/DNS configuration exactly as it was
	cp -p /etc/config/dhcp.easy-vless.bak /etc/config/dhcp
	rm -f /etc/config/dhcp-opkg
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || warn "dnsmasq restart failed - check 'logread | grep dnsmasq'"
	dnsmasq_has_nftset || die "dnsmasq-full was installed but dnsmasq still reports no nftset support"
	say "dnsmasq-full installed (backup of the DHCP config: /etc/config/dhcp.easy-vless.bak)"
	cd "$WORKDIR" || die "cannot enter $WORKDIR"
fi

# ---------------------------------------------------------------- 6. install
OLD_EV="$(installed_version easy-vless)"
say "installing easy-vless, easy-vless-sing-box, luci-app-easy-vless ${EV_VERSION}${OLD_EV:+ (installed now: ${OLD_EV})} ..."
IPKS=""
for p in $EV_PACKAGES; do IPKS="$IPKS $PKGDIR/${p}_${EV_VERSION}_all.ipk"; done
# shellcheck disable=SC2086
opkg install $IPKS || die "opkg install of the Easy VLESS packages failed"
for p in $EV_PACKAGES; do
	[ "$(installed_version "$p")" = "$EV_VERSION" ] || die "$p is not installed in version $EV_VERSION after opkg install"
done
[ -s /etc/config/easy_vless ] || die "/etc/config/easy_vless is missing after installation"

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
/etc/init.d/rpcd restart >/dev/null 2>&1 || warn "rpcd restart failed - reload the web interface later"

# ---------------------------------------------------------------- 7. service
/etc/init.d/easy_vless enable || die "/etc/init.d/easy_vless enable failed"
ENABLED="$(uci -q get easy_vless.@global[0].enabled)"
if [ "$OPT_NO_START" = "1" ]; then
	say "--no-start: service not restarted"
elif [ "$ENABLED" = "1" ]; then
	say "Main switch is on - restarting Easy VLESS ..."
	/etc/init.d/easy_vless restart || warn "restart reported an error - see /tmp/log/easy_vless.log"
	sleep 5
else
	say "Main switch is off (new installation): add a server in LuCI -> Services -> Easy VLESS, then switch Main on and use Save & Start."
fi

# ---------------------------------------------------------------- 8. status
echo
say "installed packages:"
opkg list-installed 2>/dev/null | grep -E '^(easy-vless|luci-app-easy-vless|sing-box|dnsmasq)' | sed 's/^/    /'
say "sing-box: $(singbox_version || echo 'not found')"
if dnsmasq_has_nftset; then say "dnsmasq nftset support: yes"; else warn "dnsmasq nftset support: NO - Easy VLESS will refuse to start"; fi
if /etc/init.d/easy_vless enabled 2>/dev/null; then say "service: enabled at boot"; else warn "service: not enabled at boot"; fi
STATUS="$(ubus call luci.easy_vless status 2>/dev/null | sed -n 's/^[[:space:]]*"running": \(.*\),$/\1/p' | head -n1)"
say "running: ${STATUS:-unknown}"
say "done. Web interface: LuCI -> Services -> Easy VLESS"
