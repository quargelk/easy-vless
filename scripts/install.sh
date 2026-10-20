#!/bin/sh
# Easy VLESS installer for stable OpenWrt 24.x (24.10.x: opkg, .ipk) and
# stable OpenWrt 25.x (25.12.x: apk, .apk), fw4/nftables, any target and
# architecture that the official OpenWrt feeds provide sing-box-tiny for.
# https://github.com/quargelk/easy-vless
#
# A plain, readable shell script: download it, read it, then run it as root.
#   wget -O /tmp/install.sh https://github.com/quargelk/easy-vless/releases/download/v1.2.0/install.sh
#   sh /tmp/install.sh --check          # only check the router, install nothing
#   sh /tmp/install.sh                  # install
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
# The Easy VLESS packages are architecture independent ("all" / "noarch":
# shell/Lua/JS only); every architecture-specific package (sing-box-tiny,
# dnsmasq-full, curl, kernel modules, ...) comes from the official feeds
# configured on the router for its own release, target and architecture
# (/etc/opkg/distfeeds.conf or /etc/apk/repositories.d/distfeeds.list).
#
# apk (OpenWrt 25.12): the Easy VLESS packages are verified against the
# release SHA256SUMS (like the .ipk) - they are not signed with an OpenWrt key.
# Their dependencies are installed first from the official feeds (signatures
# checked, every download finished before anything is changed); then only the
# three verified local files are installed with --allow-untrusted
# --network=no. No key is added to /etc/apk/keys.
#
# What it does, in order (stops at the first error; nothing is changed before
# step 5 has downloaded and verified every file and checked the free space):
#   1. detects and checks the router: root, OpenWrt release, target and
#      architecture (/etc/openwrt_release against the running kernel, and
#      on apk against /etc/apk/arch and the installed packages), RAM
#      (>= 256 MB) and flash/storage size (>= 128 MB), required tools, system
#      time (HTTPS certificates cannot be verified with a clock that is
#      behind - a one-time NTP synchronisation is tried), TLS library and CA
#      certificates for HTTPS, DNS, opkg, the package feeds (release, target
#      and architecture of this router), fw4/nftables, PassWall2 not running;
#      when opkg itself is missing on an OpenWrt 24.x router, it can
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

EV_VERSION="1.2.0-r1"
EV_TAG="v1.2.0"
EV_REPO="quargelk/easy-vless"
EV_BASE_URL="https://github.com/${EV_REPO}/releases/download/${EV_TAG}"
# Release date of this installer: a system clock before this date is certainly
# wrong, and TLS certificates cannot be verified with it.
EV_MIN_DATE="2026-10-20"
EV_PACKAGES="easy-vless easy-vless-sing-box luci-app-easy-vless"
SINGBOX_MIN="1.12.0"
# Supported OpenWrt major releases and the package manager each one uses
# (major = the first number of DISTRIB_RELEASE, compared as a number): every
# stable 24.x release (24.10.0 ... ) uses opkg, every stable 25.x release
# (25.12.0 ... ) apk. Release candidates and snapshots are not stable
# releases. A major release is added here only after it has been tested.
SUPPORTED_SERIES="24:opkg 25:apk"
SUPPORTED_RELEASE="24.x (24.10) or 25.x (25.12)"
OPKG_ARCHIVE="https://archive.openwrt.org/releases"
OPKG_STATUS="/usr/lib/opkg/status"
# package architectures of apk (OpenWrt 25.12)
APK_ARCH_FILE="/etc/apk/arch"
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
Easy VLESS ${EV_VERSION} installer for stable OpenWrt 24.x (24.10.x: opkg,
.ipk) and stable OpenWrt 25.x (25.12.x: apk, .apk), fw4/nftables

Usage: sh install.sh [options]

  --check, --dry-run only run the checks (router, RAM, flash, time, HTTPS,
                     package manager and feeds, sing-box, dnsmasq, release
                     files, free space); install and change nothing (files
                     are only downloaded to a temporary directory in /tmp)
  --local DIR        install the Easy VLESS packages of this router's channel
                     (.ipk for opkg, .apk for apk) and SHA256SUMS from DIR
                     instead of downloading them from GitHub
  --base-url URL     download the release files from URL (an https:// mirror
                     of ${EV_BASE_URL})
  --replace-dnsmasq  allow replacing dnsmasq with dnsmasq-full
  --yes, -y          answer "yes" to the dnsmasq question (implies
                     --replace-dnsmasq)
  --no-start         do not restart the service at the end
  --bootstrap-opkg   allow installing opkg itself when it is missing
                     (OpenWrt 24.x only, from ${OPKG_ARCHIVE})
  --force            continue on an OpenWrt release that is not a stable
                     24.x or 25.x (the channel then follows the one package
                     manager present), on an architecture mismatch or unknown
                     architecture, with package feeds of another
                     release/target/architecture, or without an opkg package
                     database (not tested; the RAM, flash and free space
                     requirements still apply). It never overrides a package
                     manager that does not fit a supported release.
  -h, --help         show this help

Optional packages (easy-vless-xray, easy-vless-geodata) are never installed
by this script.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--check|--dry-run) OPT_CHECK=1 ;;
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
pkg_file() {
	if [ "$PM" = "apk" ]; then echo "${1}-${EV_VERSION}.apk"; else echo "${1}_${EV_VERSION}_all.ipk"; fi
}

# apk_file_field FILE FIELD: a field of the package information of an .apk
# file (name, version, arch, installed-size, ...)
apk_file_field() { apk adbdump "$1" 2>/dev/null | sed -n "s/^  $2: //p" | head -n1; }

# apk_file_depends FILE: the dependencies of an .apk file, one per line
apk_file_depends() {
	apk adbdump "$1" 2>/dev/null | sed -n '/^  depends:/,/^ \{0,2\}[a-z]/s/^    - //p' | sed 's/[<>=~].*$//'
}

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
	if [ "$PM" = "apk" ]; then
		# apk replaces dnsmasq by dnsmasq-full in one transaction; when that
		# did not complete, drop the world entry it may have left and put the
		# old package back from its signed copy if it is gone
		if [ -z "$(installed_version dnsmasq-full)" ]; then
			grep -qx 'dnsmasq-full' /etc/apk/world 2>/dev/null && apk del dnsmasq-full >&2
			if [ -n "${DNSMASQ_PKG:-}" ] && [ -z "$(installed_version "$DNSMASQ_PKG")" ]; then
				apk add --repositories-file /dev/null --repository "$WORKDIR/dnsmasq/packages.adb" "$DNSMASQ_PKG" >&2 \
					|| warn "reinstalling $DNSMASQ_PKG failed - install it manually: apk add ${DNSMASQ_PKG}"
			fi
		fi
	elif [ -n "${OLD_IPK:-}" ] && [ -f "$WORKDIR/dnsmasq/$OLD_IPK" ]; then
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
# ("24.10" -> opkg, "25.12" -> apk, by the major number in SUPPORTED_SERIES),
# empty when it is not supported
series_channel() {
	local e
	[ -n "$1" ] || return 0
	for e in $SUPPORTED_SERIES; do
		[ "${e%%:*}" = "${1%%.*}" ] && { echo "${e#*:}"; return 0; }
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
	if [ -n "$extra" ]; then
		[ "$OPT_FORCE" = "1" ] || die "$APK_ARCH_FILE also lists '${extra}' besides ${DISTRIB_ARCH} - apk could install packages for another CPU. Restore the file of this firmware (one line: ${DISTRIB_ARCH}) or use --force. Nothing was changed."
		warn "$APK_ARCH_FILE also lists '${extra}' - continuing because of --force"
	fi
	foreign="$(apk query --installed --fields name,arch '*' 2>/dev/null | awk -v a="$DISTRIB_ARCH" '
		$1 == "Name:" { n = $2 }
		$1 == "Arch:" { if ($2 != a && $2 != "noarch") printf " %s(%s)", n, $2 }')"
	if [ -n "$foreign" ]; then
		[ "$OPT_FORCE" = "1" ] || die "installed packages of another architecture than ${DISTRIB_ARCH}:${foreign} - the package database does not fit this firmware. Use --force to continue anyway. Nothing was changed."
		warn "installed packages of another architecture:${foreign} - continuing because of --force"
	fi
	fam="$(apk_cpu_family)"
	own="$(arch_family "$DISTRIB_ARCH")"
	if [ -n "$fam" ] && [ -n "$own" ] && [ "$fam" != "$own" ]; then
		[ "$OPT_FORCE" = "1" ] || die "apk is built for $(apk --print-arch 2>/dev/null | head -n1), /etc/openwrt_release says ${DISTRIB_ARCH} - the release information does not fit this firmware. Nothing was changed."
		warn "apk is built for another CPU family than ${DISTRIB_ARCH} - continuing because of --force"
	fi
	say "apk architecture: ${DISTRIB_ARCH} ($APK_ARCH_FILE; apk built for $(apk --print-arch 2>/dev/null | head -n1)) - ok"
}

# detect_channel: PM (opkg or apk) from the OpenWrt release and the package
# manager that is present; stops on every inconsistency before anything is
# changed. opkg may be missing on 24.10 (it can be bootstrapped below).
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
	if [ "$PM" = "apk" ]; then ensure_https_apk; return; fi
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

# ensure_https_apk: ensure_https for apk. Official .apk files are not signed
# one by one: the signed index of their feed (packages.adb) lists them. --local
# DIR therefore holds the base feed index and the TLS/CA packages; DIR is used
# as the only repository, so apk checks the index signature with
# /etc/apk/keys and every package against the index.
ensure_https_apk() {
	local f b names="" local_hint
	local_hint="On a PC, download https://downloads.openwrt.org/releases/${DISTRIB_RELEASE}/packages/${DISTRIB_ARCH}/base/packages.adb plus the .apk files of libustream-mbedtls and ca-bundle from the same directory, copy them into one directory on the router (scp -O) and run this installer with --local DIR (README section \"HTTPS на новом роутере\", HTTPS on a new router)"
	[ -n "$OPT_LOCAL" ] && [ -f "$OPT_LOCAL/packages.adb" ] || die "HTTPS does not work on this router: $(explain_download_error "$HTTPS_URL" "$HTTPS_ERR"). Nothing can be downloaded without it (there is no HTTP fallback). ${local_hint}"
	for f in "$OPT_LOCAL"/*.apk; do
		[ -f "$f" ] || continue
		b="$(basename "$f")"
		case "$b" in
			libustream-*|libmbedtls*|libwolfssl*|libopenssl*|ca-bundle-*|ca-certificates-*) names="$names $(apk_file_field "$f" name)" ;;
		esac
	done
	[ -n "$names" ] || die "HTTPS does not work ($(echo "$HTTPS_ERR" | tr '\n' ' ')) and $OPT_LOCAL has no TLS/CA package (libustream-mbedtls*.apk, ca-bundle*.apk). ${local_hint}"
	[ "$OPT_CHECK" = "1" ] && die "--check: HTTPS does not work; the installer would install${names} from $OPT_LOCAL (index signature verified) - run it without --check"
	say "installing the HTTPS prerequisites from ${OPT_LOCAL} (signed index packages.adb):${names}"
	# shellcheck disable=SC2086
	apk add --repositories-file /dev/null --repository "$OPT_LOCAL/packages.adb" $names \
		|| die "apk add of${names} from $OPT_LOCAL failed (index signature or package checksum not valid, or a dependency is missing there)"
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

# ---------------------------------------------------------------- feeds

APK_DISTFEEDS=/etc/apk/repositories.d/distfeeds.list

# apk_feeds FILE...: "<name> <url>" of the repository URLs in FILEs; name:
# core (target packages), kmods, or the last part of the path (base, luci, ...)
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
	local log=/tmp/easy-vless-apk-update.log feeds name url bad="" soft="" text rc
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
		die "$(explain_download_error "$(awk -v n="$1" '$1 == n { print $2; exit }' "$feeds")" "$text") (full log: $log)"
	fi
	[ -z "$soft" ] || warn "optional package feeds not available:${soft} (not needed by Easy VLESS; see $log)"
	[ "$rc" = "0" ] || [ -n "$soft" ] || die "apk update failed: $(echo "${text:-exit code $rc}" | tr '\n' ' ') (full log: $log)"
}

pm_update() {
	if [ "$PM" = "apk" ]; then apk_update; else opkg_update; fi
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
		[ "$OPT_FORCE" = "1" ] || die "the package feeds are not the ones of OpenWrt ${DISTRIB_RELEASE} ${DISTRIB_TARGET} ${DISTRIB_ARCH} - packages for another CPU/kernel would be installed. Restore the original $conf of this firmware (or use --force)"
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
	local wants="" own_kb=0 p f dep sz res missing wrong
	if [ "$PM" = "apk" ]; then check_space_apk; return; fi
	for p in $EV_PACKAGES; do
		f="$PKGDIR/$(pkg_file "$p")"
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
# whole installation (the verified local files, sing-box-tiny, dnsmasq-full
# and every dependency from the feeds of this router) without changing
# anything; the sizes of the new feed packages come from the signed indexes.
check_space_apk() {
	local files="" wants="" own_kb=0 p f sz names res wrong log="$WORKDIR/apk-simulate.log" err
	for p in $EV_PACKAGES; do
		f="$PKGDIR/$(pkg_file "$p")"
		files="$files $f"
		sz="$(apk_file_field "$f" installed-size)"
		[ -n "$sz" ] || die "cannot read the package data of $(basename "$f")"
		own_kb=$((own_kb + sz / 1024 + 1))
	done
	[ "$SB_ACTION" = "install" ] && wants="sing-box-tiny"
	[ "$NEED_DNSMASQ" = "1" ] && wants="$wants dnsmasq-full"
	# shellcheck disable=SC2086
	if ! apk add --simulate --allow-untrusted $files $wants >"$log" 2>&1; then
		err="$(grep -v -e '^(' -e '^OK:' "$log" | head -n 8 | tr '\n' ' ')"
		die "apk cannot resolve the installation with the package feeds of this router (${DISTRIB_ARCH}): ${err:-see $log} - Easy VLESS cannot be installed on this architecture/firmware with the official feeds"
	fi
	# new or replaced packages from the feeds (the Easy VLESS packages are
	# counted from their own files)
	names="$(sed -n -E 's/^\([ 0-9]+\/[ 0-9]+\) (Installing|Upgrading|Downgrading|Replacing) ([^ ]+) .*$/\2/p' "$log" \
		| grep -vx -e easy-vless -e easy-vless-sing-box -e luci-app-easy-vless | sort -u)"
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
say "Easy VLESS ${EV_VERSION} installer"

[ "$(id -u 2>/dev/null)" = "0" ] || die "run this script as root"
[ -r /etc/openwrt_release ] || die "/etc/openwrt_release not found - this is not OpenWrt"
. /etc/openwrt_release
say "OpenWrt: ${DISTRIB_RELEASE:-?} (${DISTRIB_REVISION:-?}), target ${DISTRIB_TARGET:-?}, architecture ${DISTRIB_ARCH:-?}"

[ -n "${DISTRIB_ARCH:-}" ] || die "DISTRIB_ARCH is empty in /etc/openwrt_release"
say "kernel: $(uname -m 2>/dev/null) $(uname -r 2>/dev/null), model: $(cat /tmp/sysinfo/model 2>/dev/null || echo unknown)"
if [ -z "$(arch_family "$DISTRIB_ARCH")" ]; then
	[ "$OPT_FORCE" = "1" ] || die "architecture ${DISTRIB_ARCH} is not supported by this installer. Use --force to try anyway (sing-box-tiny must exist in the official feed of this architecture)."
	warn "unknown architecture ${DISTRIB_ARCH} - continuing because of --force"
elif ! arch_matches_kernel; then
	[ "$OPT_FORCE" = "1" ] || die "architecture mismatch: /etc/openwrt_release says ${DISTRIB_ARCH}, the kernel runs on $(uname -m). Use --force to continue anyway."
	warn "architecture mismatch (${DISTRIB_ARCH} / $(uname -m)) - continuing because of --force"
fi
# release series + package manager -> opkg/.ipk or apk/.apk (or stop)
detect_channel

MISSING=""
for t in wget tar gzip sha256sum awk sed grep df pgrep uci mktemp; do
	command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
[ -z "$MISSING" ] || die "required tools missing:${MISSING}"

WORKDIR="$(mktemp -d /tmp/easy-vless-install.XXXXXX)" || die "cannot create a temporary directory in /tmp"
# apk options for every installation from the feeds: all downloads (to /tmp)
# are finished before the transaction changes anything
APK_DL=""
if [ "$PM" = "apk" ]; then
	mkdir -p "$WORKDIR/apk-cache" || die "cannot create $WORKDIR/apk-cache"
	APK_DL="--cache-dir $WORKDIR/apk-cache --cache-predownload"
fi

check_system_requirements

check_clock
check_https
if [ -z "$OPT_LOCAL" ] && [ "${HTTPS_BROKEN:-0}" = "0" ]; then
	check_dns "$(url_host "$EV_BASE_URL")"
fi
check_feeds

if [ "$PM" = "opkg" ] && ! command -v opkg >/dev/null 2>&1; then
	case "$(release_series "${DISTRIB_RELEASE:-}")" in
		24.*) ;;
		*) die "opkg not found, and bootstrapping it is only supported on OpenWrt 24.x" ;;
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
pm_update
register_bootstrapped

# ---------------------------------------------------------------- 3. sing-box
SB_ACTION=""
SB_VER="$(singbox_version || true)"
if [ -n "$SB_VER" ]; then
	version_ge "$SB_VER" "$SINGBOX_MIN" || die "installed sing-box ${SB_VER} is older than ${SINGBOX_MIN}. Upgrade it (${PM} upgrade sing-box or sing-box-tiny) and run this script again."
	say "sing-box ${SB_VER} is already installed - kept"
else
	for p in sing-box sing-box-tiny; do
		[ -n "$(installed_version "$p")" ] && die "package $p is installed but the sing-box binary does not work - fix or remove it first"
	done
	SB_FEED_VER="$(pkg_field sing-box-tiny Version)"
	[ -n "$SB_FEED_VER" ] || die "sing-box-tiny is not available in the package feeds of this router (${DISTRIB_ARCH}). Install sing-box >= ${SINGBOX_MIN} manually ($( [ "$PM" = apk ] && echo 'apk add' || echo 'opkg install') sing-box-tiny or sing-box) and run this script again."
	SB_FEED_ARCH="$(pkg_field sing-box-tiny Architecture)"
	case "$SB_FEED_ARCH" in
		"$DISTRIB_ARCH"|all|noarch) ;;
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
	if [ "$PM" = "apk" ]; then
		for p in dnsmasq dnsmasq-dhcpv6 dnsmasq-full; do
			[ -n "$(installed_version "$p")" ] && { DNSMASQ_PKG="$p"; break; }
		done
	else
		DNSMASQ_PKG="$(opkg list-installed 2>/dev/null | awk '$1 ~ /^dnsmasq/ { print $1; exit }')"
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
	[ -d "$OPT_LOCAL" ] || die "--local: $OPT_LOCAL is not a directory"
	[ -f "$OPT_LOCAL/SHA256SUMS" ] || die "--local: SHA256SUMS not found in $OPT_LOCAL"
	cp "$OPT_LOCAL/SHA256SUMS" "$PKGDIR/SHA256SUMS" || die "--local: cannot copy SHA256SUMS"
	EXT=".ipk"; [ "$PM" = "apk" ] && EXT=".apk"
	for p in $EV_PACKAGES; do
		f="$(pkg_file "$p")"
		if [ ! -f "$OPT_LOCAL/$f" ]; then
			found=""
			for g in "$OPT_LOCAL"/*"$EXT"; do [ -f "$g" ] && found="$found $(basename "$g")"; done
			die "--local: $f not found in $OPT_LOCAL (this installer is for Easy VLESS ${EV_VERSION}, package manager ${PM}; ${EXT} files there:${found:- none})"
		fi
		cp "$OPT_LOCAL/$f" "$PKGDIR/$f" || die "--local: cannot copy $f"
	done
	say "Easy VLESS packages taken from $OPT_LOCAL"
else
	say "downloading Easy VLESS ${EV_VERSION} from ${EV_BASE_URL}"
	fetch "${EV_BASE_URL}/SHA256SUMS" "$PKGDIR/SHA256SUMS" "SHA256SUMS of Easy VLESS ${EV_VERSION}"
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
	# the package inside must be the one its file name promises
	if [ "$PM" = "apk" ]; then
		got="$(apk_file_field "$PKGDIR/$f" name) $(apk_file_field "$PKGDIR/$f" version) $(apk_file_field "$PKGDIR/$f" arch)"
		[ "$got" = "$p $EV_VERSION noarch" ] || die "$f is not a valid apk package of $p $EV_VERSION (found: '${got}') - nothing was installed"
	else
		got="$(ipk_control "$PKGDIR/$f" Package) $(ipk_control "$PKGDIR/$f" Version) $(ipk_control "$PKGDIR/$f" Architecture)"
		[ "$got" = "$p $EV_VERSION all" ] || die "$f is not a valid package of $p $EV_VERSION (found: '${got}') - nothing was installed"
	fi
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
	if [ "$PM" = "apk" ]; then
		# shellcheck disable=SC2086
		apk add $APK_DL sing-box-tiny || die "apk add sing-box-tiny failed"
	else
		opkg install sing-box-tiny || die "opkg install sing-box-tiny failed"
	fi
	SB_VER="$(singbox_version || true)"
	[ -n "$SB_VER" ] || die "sing-box-tiny was installed but 'sing-box version' does not work"
	say "sing-box ${SB_VER} installed"
fi

# ---------------------------------------------------------------- 4b. dnsmasq
# apk: dnsmasq-full provides dnsmasq, so "apk add dnsmasq-full" replaces it in
# one transaction, with every download finished first. A signed copy of the
# old package is fetched before for the rollback, /etc/config/dhcp is backed
# up and put back as it was.
replace_dnsmasq_apk() {
	local u
	say "replacing ${DNSMASQ_PKG:-dnsmasq} with dnsmasq-full ..."
	mkdir -p "$WORKDIR/dnsmasq" || die "cannot create $WORKDIR/dnsmasq"
	if [ -n "$DNSMASQ_PKG" ]; then
		# rollback copy: the package and the signed index of its feed, so
		# that it can be reinstalled without DNS (official .apk files are
		# not signed one by one - the index signature covers them)
		u="$(official_feeds | awk '$1 == "base" { print $2; exit }')"
		[ -n "$u" ] || die "the base feed is not configured - cannot prepare a rollback copy of $DNSMASQ_PKG; nothing was changed"
		fetch "$u" "$WORKDIR/dnsmasq/packages.adb" "package index of the base feed (rollback copy of $DNSMASQ_PKG)"
		apk fetch -o "$WORKDIR/dnsmasq" "$DNSMASQ_PKG" >/dev/null || die "apk fetch $DNSMASQ_PKG (rollback copy) failed - nothing was changed"
		OLD_IPK="$(cd "$WORKDIR/dnsmasq" && ls "${DNSMASQ_PKG}"-[0-9]*.apk 2>/dev/null | head -n1)"
		[ -n "$OLD_IPK" ] || die "rollback copy of $DNSMASQ_PKG not found - nothing was changed"
	fi
	cp -p /etc/config/dhcp /etc/config/dhcp.easy-vless.bak 2>/dev/null || die "cannot back up /etc/config/dhcp - nothing was changed"
	DNSMASQ_STAGE="removed"
	# fault injection for the rollback test (tests/ci/installer-scenarios.sh)
	[ "${EV_TEST_SIGNAL_AFTER_DNSMASQ_REMOVE:-0}" = "1" ] && kill -TERM $$
	# shellcheck disable=SC2086
	if [ "${EV_TEST_FAIL_DNSMASQ_INSTALL:-0}" = "1" ] || ! apk add $APK_DL dnsmasq-full; then
		warn "installing dnsmasq-full failed"
		dnsmasq_rollback
		die "dnsmasq-full could not be installed; ${DNSMASQ_PKG:-dnsmasq} was restored"
	fi
	DNSMASQ_STAGE=""
	# keep the router's DHCP/DNS configuration exactly as it was
	cp -p /etc/config/dhcp.easy-vless.bak /etc/config/dhcp
	rm -f /etc/config/dhcp.apk-new
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || warn "dnsmasq restart failed - check 'logread | grep dnsmasq'"
	dnsmasq_has_nftset || die "dnsmasq-full was installed but dnsmasq still reports no nftset support"
	say "dnsmasq-full installed (backup of the DHCP config: /etc/config/dhcp.easy-vless.bak)"
}
if [ "$DNSMASQ_ACTION" = "replace" ] && [ "$PM" = "apk" ]; then
	replace_dnsmasq_apk
elif [ "$DNSMASQ_ACTION" = "replace" ]; then
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
WAS_INSTALLED=""
for p in $EV_PACKAGES; do
	IPKS="$IPKS $PKGDIR/$(pkg_file "$p")"
	[ -n "$(installed_version "$p")" ] && WAS_INSTALLED="$WAS_INSTALLED $p"
done
PM_INSTALL="opkg install"; PM_REMOVE="opkg remove"
[ "$PM" = "apk" ] && { PM_INSTALL="apk add"; PM_REMOVE="apk del"; }
# apk: (1) the dependencies of the three packages from the official feeds
# (signatures checked, downloads first) under the temporary virtual package
# .easy-vless-deps; (2) only the three verified local files, without network
# and without a signature (they are verified against SHA256SUMS); (3) the
# virtual package is removed - the dependencies stay as dependencies of
# Easy VLESS, and "apk del" of Easy VLESS can remove them again.
apk_install_local() {
	local deps f rc
	deps="$(for f in "$@"; do apk_file_depends "$f"; done | sort -u \
		| grep -vx -e easy-vless -e easy-vless-sing-box -e luci-app-easy-vless -e libc)"
	if [ -n "$deps" ]; then
		# shellcheck disable=SC2086
		apk add $APK_DL --virtual .easy-vless-deps $deps || return 1
	fi
	apk add --allow-untrusted --network=no "$@"
	rc=$?
	[ -z "$deps" ] || apk del .easy-vless-deps >/dev/null 2>&1 \
		|| warn "could not remove the temporary virtual package .easy-vless-deps ('apk del .easy-vless-deps')"
	return "$rc"
}
# fault injection for the partial installation test (tests/ci/installer-
# scenarios.sh): only the first package gets installed, then opkg "fails"
ev_install() {
	if [ "${EV_TEST_FAIL_EV_INSTALL:-0}" = "1" ]; then
		# shellcheck disable=SC2086
		set -- $IPKS
		if [ "$PM" = "apk" ]; then apk_install_local "$1"; else opkg install "$1"; fi
		return 1
	fi
	# shellcheck disable=SC2086
	if [ "$PM" = "apk" ]; then apk_install_local $IPKS; else opkg install $IPKS; fi
}
if ! ev_install; then
	# opkg installs the three packages one after another: a failure in the
	# middle must not leave a part of Easy VLESS behind
	NOW=""
	for p in $EV_PACKAGES; do NOW="$NOW ${p}=$(installed_version "$p")"; done
	if [ -z "$WAS_INSTALLED" ]; then
		warn "$PM_INSTALL of the Easy VLESS packages failed - removing the part that was installed"
		for p in luci-app-easy-vless easy-vless-sing-box easy-vless; do
			[ -n "$(installed_version "$p")" ] && $PM_REMOVE "$p" >&2
		done
		LEFT=""
		for p in $EV_PACKAGES; do [ -n "$(installed_version "$p")" ] && LEFT="$LEFT $p"; done
		[ -z "$LEFT" ] || die "$PM_INSTALL of the Easy VLESS packages failed, and these could not be removed again:${LEFT}. Remove them with '$PM_REMOVE${LEFT}', fix the problem shown above and run the installer again"
		die "$PM_INSTALL of the Easy VLESS packages failed. No Easy VLESS package is left installed (sing-box and dnsmasq-full stay). Fix the problem shown above and run the installer again"
	fi
	die "$PM_INSTALL of the Easy VLESS packages failed during the upgrade${OLD_EV:+ from ${OLD_EV}}. Installed now:${NOW} (the three packages must have the same version). The configuration is kept. Fix the problem shown above and run this installer again; to go back, run the install.sh of the previous release"
fi
for p in $EV_PACKAGES; do
	[ "$(installed_version "$p")" = "$EV_VERSION" ] || die "$p is not installed in version $EV_VERSION after $PM_INSTALL"
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
say "installed packages (${PM}):"
installed_list | sed 's/^/    /'
say "sing-box: $(singbox_version || echo 'not found')"
if dnsmasq_has_nftset; then say "dnsmasq nftset support: yes"; else warn "dnsmasq nftset support: NO - Easy VLESS will refuse to start"; fi
if /etc/init.d/easy_vless enabled 2>/dev/null; then say "service: enabled at boot"; else warn "service: not enabled at boot"; fi
STATUS="$(ubus call luci.easy_vless status 2>/dev/null | sed -n 's/^[[:space:]]*"running": \(.*\),$/\1/p' | head -n1)"
say "running: ${STATUS:-unknown}"
say "done. Web interface: LuCI -> Services -> Easy VLESS"
