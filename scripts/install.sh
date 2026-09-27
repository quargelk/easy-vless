#!/bin/sh
# Easy VLESS installer for OpenWrt 24.10 (opkg, fw4/nftables).
# https://github.com/quargelk/easy-vless
#
# A plain, readable shell script: download it, read it, then run it as root.
#   wget -O /tmp/install.sh https://github.com/quargelk/easy-vless/releases/download/v0.5.1-r2/install.sh
#   sh /tmp/install.sh --check          # only check the router, install nothing
#   sh /tmp/install.sh                  # install
#
# What it does, in order (stops at the first error; nothing is changed before
# step 5 has downloaded and verified every file):
#   1. checks the router: root, OpenWrt release and architecture, required
#      tools, system time (HTTPS certificates cannot be verified with a clock
#      that is behind - a one-time NTP synchronisation is tried), TLS library
#      and CA certificates for HTTPS, DNS, opkg, fw4/nftables, PassWall2 not
#      running, free space; when opkg itself is missing on an OpenWrt 24.10.x
#      router, it can bootstrap opkg from the official package archive of this
#      release and architecture (--bootstrap-opkg or an interactive "y"; see
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
#      against the release SHA256SUMS (or uses --local DIR);
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

EV_VERSION="0.5.1-r2"
EV_TAG="v0.5.1-r2"
EV_REPO="quargelk/easy-vless"
EV_BASE_URL="https://github.com/${EV_REPO}/releases/download/${EV_TAG}"
# Release date of this installer: a system clock before this date is certainly
# wrong, and TLS certificates cannot be verified with it.
EV_MIN_DATE="2026-09-27"
EV_PACKAGES="easy-vless easy-vless-sing-box luci-app-easy-vless"
SINGBOX_MIN="1.12.0"
SUPPORTED_RELEASE="24.10"
OPKG_ARCHIVE="https://archive.openwrt.org/releases"
OPKG_STATUS="/usr/lib/opkg/status"

OPT_CHECK=0
OPT_LOCAL=""
OPT_REPLACE_DNSMASQ=0
OPT_YES=0
OPT_NO_START=0
OPT_FORCE=0
OPT_BOOTSTRAP_OPKG=0

WORKDIR=""
DNSMASQ_STAGE=""
BOOTSTRAPPED=""

say()  { echo "[easy-vless] $*"; }
warn() { echo "[easy-vless] WARNING: $*" >&2; }
die()  { echo "[easy-vless] ERROR: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Easy VLESS ${EV_VERSION} installer for OpenWrt ${SUPPORTED_RELEASE}.x (opkg, fw4/nftables)

Usage: sh install.sh [options]

  --check            only run the checks (router, time, HTTPS, opkg feeds,
                     sing-box, dnsmasq); install and change nothing
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
                     on an architecture mismatch, or without an opkg package
                     database (not tested)
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

is_ipv4() { case "$1" in ""|*[!0-9.]*) return 1 ;; esac; return 0; }

url_host() { echo "$1" | sed 's#^[a-z]*://##; s#[/:?].*##'; }

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
			echo "the TLS certificate of ${host} is not trusted: the CA certificates are missing or outdated. Install the package ca-bundle (see the README section \"HTTPS on a new router\" for a copy made on a PC); never disable certificate checks" ;;
		*"unknown error"*|*"not yet valid"*|*"has expired"*)
			echo "the TLS certificate of ${host} could not be verified - most likely the system time is wrong (now: $(date -u '+%Y-%m-%d %H:%M UTC')). Set the time, e.g. 'ntpd -n -q -p 0.openwrt.pool.ntp.org', and run the installer again" ;;
		*"SSL support not available"*)
			echo "uclient-fetch has no TLS library: install libustream-mbedtls and ca-bundle" ;;
		*"Operation not permitted"*|*"Failed to send request"*)
			if ! is_ipv4 "$host" && command -v nslookup >/dev/null 2>&1 && ! nslookup "$host" >/dev/null 2>&1; then
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

# arch_matches_kernel: DISTRIB_ARCH is plausible for the running kernel
# (a copied /etc/openwrt_release or a wrong image must not make the
# installer fetch binaries for another CPU)
arch_matches_kernel() {
	local m
	m="$(uname -m 2>/dev/null)"
	case "$DISTRIB_ARCH" in
		aarch64*) [ "$m" = "aarch64" ] ;;
		x86_64) [ "$m" = "x86_64" ] ;;
		i386*) case "$m" in i?86) return 0 ;; esac; return 1 ;;
		arm_*) case "$m" in arm*|aarch64) return 0 ;; esac; return 1 ;;
		mips64*) [ "$m" = "mips64" ] ;;
		mips*) [ "$m" = "mips" ] ;;
		riscv64*) [ "$m" = "riscv64" ] ;;
		loongarch64*) [ "$m" = "loongarch64" ] ;;
		*) return 0 ;;
	esac
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

# check_https: a downloader, a TLS library and CA certificates
check_https() {
	local w
	command -v wget >/dev/null 2>&1 || die "wget (uclient-fetch) not found - install uclient-fetch, libustream-mbedtls and ca-bundle"
	w="$(readlink -f "$(command -v wget)" 2>/dev/null)"
	case "$w" in
		*/uclient-fetch)
			any_exists /lib/libustream-ssl.so* /usr/lib/libustream-ssl.so* \
				|| die "uclient-fetch has no TLS library (libustream-ssl.so): install libustream-mbedtls and ca-bundle (see the README section \"HTTPS on a new router\")" ;;
	esac
	any_exists /etc/ssl/certs/*.crt \
		|| die "no CA certificates in /etc/ssl/certs (package ca-bundle): HTTPS certificates cannot be verified. See the README section \"HTTPS on a new router\" for installing ca-bundle from a copy made on a PC"
	say "HTTPS: $(basename "${w:-wget}"), TLS library and CA certificates present"
}

# check_dns HOST...: every host resolves (only when nslookup is available)
check_dns() {
	local h
	command -v nslookup >/dev/null 2>&1 || return 0
	for h in "$@"; do
		is_ipv4 "$h" && continue
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
	fetch "${BOOT_BASE}/${file}" "$dir/$file" "$name package"
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
	BOOT_DIR="$WORKDIR/opkg-bootstrap"
	mkdir -p "$BOOT_DIR" || die "cannot create $BOOT_DIR"
	# refuse before changing anything when opkg could not work afterwards
	[ -s /etc/opkg/distfeeds.conf ] || die "/etc/opkg/distfeeds.conf is missing: opkg would have no package feeds - configure them first"
	if [ ! -s "$OPKG_STATUS" ]; then
		[ "$OPT_FORCE" = "1" ] || die "the opkg package database ($OPKG_STATUS) is missing: opkg would treat every installed package as missing and reinstall base packages. Use --force only if you know this is intended"
		warn "$OPKG_STATUS is missing - continuing because of --force"
	fi
	say "bootstrapping opkg from ${BOOT_BASE}"
	fetch "${BOOT_BASE}/Packages" "$BOOT_DIR/Packages" "package index of ${DISTRIB_RELEASE}/${DISTRIB_ARCH}/base"
	fetch "${BOOT_BASE}/Packages.sig" "$BOOT_DIR/Packages.sig" "package index signature"
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
if ! arch_matches_kernel; then
	[ "$OPT_FORCE" = "1" ] || die "architecture mismatch: /etc/openwrt_release says ${DISTRIB_ARCH}, the kernel runs on $(uname -m). Use --force to continue anyway."
	warn "architecture mismatch (${DISTRIB_ARCH} / $(uname -m)) - continuing because of --force"
fi

MISSING=""
for t in wget tar gzip sha256sum awk sed grep df pgrep uci mktemp; do
	command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
[ -z "$MISSING" ] || die "required tools missing:${MISSING}"

WORKDIR="$(mktemp -d /tmp/easy-vless-install.XXXXXX)" || die "cannot create a temporary directory in /tmp"

check_clock
check_https
if [ -z "$OPT_LOCAL" ]; then
	check_dns "$(url_host "$EV_BASE_URL")"
fi

if ! command -v opkg >/dev/null 2>&1; then
	command -v apk >/dev/null 2>&1 && die "this OpenWrt uses apk instead of opkg - not supported by Easy VLESS ${EV_VERSION} (OpenWrt ${SUPPORTED_RELEASE}.x with opkg is required)"
	case "${DISTRIB_RELEASE:-}" in
		${SUPPORTED_RELEASE}.*) ;;
		*) die "opkg not found, and bootstrapping it is only supported on OpenWrt ${SUPPORTED_RELEASE}.x" ;;
	esac
	say "opkg is not installed. It can be installed from ${OPKG_ARCHIVE}/${DISTRIB_RELEASE}/packages/${DISTRIB_ARCH}/base (package 'opkg' of this release and architecture)."
	[ "$OPT_CHECK" = "1" ] && die "--check: opkg is missing - the installer can bootstrap it (run without --check and confirm, or add --bootstrap-opkg); the remaining checks need opkg"
	if [ "$OPT_BOOTSTRAP_OPKG" = "1" ] || ask "Install opkg now?"; then
		check_dns "$(url_host "$OPKG_ARCHIVE")"
		bootstrap_opkg
	else
		die "opkg is required. Run again with --bootstrap-opkg."
	fi
fi

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
SB_SIZE=""
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
	SB_SIZE="$(pkg_field sing-box-tiny Installed-Size)"
	say "sing-box-tiny ${SB_FEED_VER} (${SB_FEED_ARCH}) found in the official feed"
	SB_ACTION="install"
fi

# free space on the overlay (packages are installed there)
FREE_KB="$(df -k /overlay 2>/dev/null | awk 'NR == 2 { print $4 }')"
[ -n "$FREE_KB" ] || FREE_KB="$(df -k / 2>/dev/null | awk 'NR == 2 { print $4 }')"
NEED_KB=3072
[ -n "${SB_SIZE:-}" ] && NEED_KB=$(( NEED_KB + SB_SIZE / 1024 ))
if [ -n "$FREE_KB" ]; then
	say "free space: $((FREE_KB / 1024)) MB, needed about $((NEED_KB / 1024 + 1)) MB"
	[ "$FREE_KB" -ge "$NEED_KB" ] || die "not enough free space on the overlay (${FREE_KB} KB free, about ${NEED_KB} KB needed)"
else
	warn "could not determine free space"
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

if [ "$OPT_CHECK" = "1" ]; then
	say "check finished: no blocking problem found"
	[ "$SB_ACTION" = "install" ] && say "  the installer will install sing-box-tiny from the official feed"
	[ "$NEED_DNSMASQ" = "1" ] && say "  the installer will ask to replace dnsmasq with dnsmasq-full (or use --replace-dnsmasq)"
	exit 0
fi

# ---------------------------------------------------------------- 5. packages
# Every file is downloaded (or copied) and verified before anything is changed.
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
