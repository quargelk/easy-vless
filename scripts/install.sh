#!/bin/sh
# Easy VLESS installer for OpenWrt 24.10 (opkg, fw4/nftables).
# https://github.com/quargelk/easy-vless
#
# A plain, readable shell script: download it, read it, then run it as root.
#   wget -O /tmp/install.sh https://github.com/quargelk/easy-vless/releases/download/v0.5.1/install.sh
#   sh /tmp/install.sh --check          # only check the router, install nothing
#   sh /tmp/install.sh                  # install
#
# What it does, in order (stops at the first error):
#   1. checks the router: root, OpenWrt release, opkg, fw4/nftables, PassWall2
#      not running, free space;
#   2. opkg update;
#   3. sing-box: keeps an installed sing-box/sing-box-tiny >= 1.12.0, otherwise
#      installs sing-box-tiny from the official OpenWrt package feed of this
#      router (opkg selects the package for this router's architecture and
#      verifies the feed signature and package checksum);
#   4. dnsmasq-full (dnsmasq with nftset support, required by Easy VLESS):
#      only replaces the default dnsmasq after explicit confirmation
#      (--replace-dnsmasq or an interactive "y"), with a rollback package
#      downloaded first and a backup of /etc/config/dhcp;
#   5. downloads the Easy VLESS packages of this release and verifies them
#      against the release SHA256SUMS (or uses --local DIR);
#   6. installs easy-vless, easy-vless-sing-box and luci-app-easy-vless
#      (existing /etc/config/easy_vless is kept; opkg treats it as a conffile);
#   7. enables the service; restarts it only when it is already switched on
#      (Main switch) - a fresh install is started from the web interface
#      after a server has been added;
#   8. prints a status summary.
#
# Options:
#   --check            only run the checks of steps 1-4 (refreshes the opkg
#                      package lists), install and change nothing
#   --local DIR        install the Easy VLESS .ipk files and SHA256SUMS from DIR
#                      instead of downloading them
#   --replace-dnsmasq  allow replacing dnsmasq with dnsmasq-full
#   --yes              answer "yes" to the dnsmasq question (implies
#                      --replace-dnsmasq)
#   --no-start         do not restart the service at the end
#   --force            continue on an OpenWrt release other than 24.10.x
#   -h, --help         show this help
#
# Optional packages (easy-vless-xray, easy-vless-geodata) are never installed
# by this script.

set -u

EV_VERSION="0.5.1-r1"
EV_TAG="v0.5.1"
EV_REPO="quargelk/easy-vless"
EV_BASE_URL="https://github.com/${EV_REPO}/releases/download/${EV_TAG}"
EV_PACKAGES="easy-vless easy-vless-sing-box luci-app-easy-vless"
SINGBOX_MIN="1.12.0"
SUPPORTED_RELEASE="24.10"
WORKDIR="/tmp/easy-vless-install"

OPT_CHECK=0
OPT_LOCAL=""
OPT_REPLACE_DNSMASQ=0
OPT_YES=0
OPT_NO_START=0
OPT_FORCE=0

say()  { echo "[easy-vless] $*"; }
warn() { echo "[easy-vless] WARNING: $*" >&2; }
die()  { echo "[easy-vless] ERROR: $*" >&2; exit 1; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
	case "$1" in
		--check) OPT_CHECK=1 ;;
		--local) [ $# -ge 2 ] || die "--local needs a directory"; OPT_LOCAL="$2"; shift ;;
		--replace-dnsmasq) OPT_REPLACE_DNSMASQ=1 ;;
		--yes|-y) OPT_YES=1; OPT_REPLACE_DNSMASQ=1 ;;
		--no-start) OPT_NO_START=1 ;;
		--force) OPT_FORCE=1 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1 (see --help)" ;;
	esac
	shift
done

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
	local sum
	sum="$(pkg_field "$1" SHA256sum)"
	if [ -z "$sum" ]; then
		for l in /var/opkg-lists/*; do
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
dnsmasq_has_nftset() { dnsmasq -v 2>/dev/null | tr ' \t' '\n\n' | grep -qx nftset; }

# ---------------------------------------------------------------- 1. checks
say "Easy VLESS ${EV_VERSION} installer"

[ "$(id -u 2>/dev/null)" = "0" ] || die "run this script as root"
[ -r /etc/openwrt_release ] || die "/etc/openwrt_release not found - this is not OpenWrt"
. /etc/openwrt_release
say "OpenWrt: ${DISTRIB_RELEASE:-?} (${DISTRIB_REVISION:-?}), target ${DISTRIB_TARGET:-?}, architecture ${DISTRIB_ARCH:-?}"

command -v opkg >/dev/null 2>&1 || die "opkg not found. This release of Easy VLESS supports opkg-based OpenWrt ${SUPPORTED_RELEASE}.x only (OpenWrt with apk is not supported yet)."
case "${DISTRIB_RELEASE:-}" in
	${SUPPORTED_RELEASE}.*) ;;
	*)
		[ "$OPT_FORCE" = "1" ] || die "OpenWrt ${DISTRIB_RELEASE:-unknown} is not supported by this installer (tested: ${SUPPORTED_RELEASE}.x). Use --force to try anyway."
		warn "OpenWrt ${DISTRIB_RELEASE:-unknown} is not a tested release - continuing because of --force"
		;;
esac
[ -n "${DISTRIB_ARCH:-}" ] || die "DISTRIB_ARCH is empty in /etc/openwrt_release"

command -v fw4 >/dev/null 2>&1 || die "fw4 (firewall4) not found - Easy VLESS needs OpenWrt's nftables firewall (fw4)"
command -v nft >/dev/null 2>&1 || die "nft not found - Easy VLESS needs nftables"

if pgrep -f /usr/share/passwall2/ >/dev/null 2>&1 || nft list table inet passwall2 >/dev/null 2>&1; then
	die "PassWall2 is running. Stop and disable it first: /etc/init.d/passwall2 stop; /etc/init.d/passwall2 disable"
fi

if [ "$OPT_CHECK" = "0" ]; then
	rm -rf "$WORKDIR"
	mkdir -p "$WORKDIR" || die "cannot create $WORKDIR"
fi

# ---------------------------------------------------------------- 2. feeds
say "opkg update ..."
opkg update >/tmp/easy-vless-opkg-update.log 2>&1 || die "opkg update failed (see /tmp/easy-vless-opkg-update.log). Check the internet connection and /etc/opkg/distfeeds.conf."
grep -qs '^option check_signature' /etc/opkg.conf || warn "opkg signature checking (option check_signature) is not enabled in /etc/opkg.conf"

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
	say "  - if installing dnsmasq-full fails, ${DNSMASQ_PKG:-dnsmasq} is reinstalled from its downloaded file."
	if [ "$OPT_CHECK" = "1" ]; then
		say "(--check: nothing is changed; run without --check to be asked, or with --replace-dnsmasq)"
	elif [ "$OPT_REPLACE_DNSMASQ" = "1" ] && [ "$OPT_YES" = "1" ]; then
		DNSMASQ_ACTION="replace"
	elif [ -t 0 ]; then
		printf '[easy-vless] Replace %s with dnsmasq-full now? [y/N] ' "${DNSMASQ_PKG:-dnsmasq}"
		read -r answer
		case "$answer" in
			y|Y|yes|YES) DNSMASQ_ACTION="replace" ;;
		esac
	elif [ "$OPT_REPLACE_DNSMASQ" = "1" ]; then
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
cd "$WORKDIR" || die "cannot enter $WORKDIR"
if [ -n "$OPT_LOCAL" ]; then
	[ -d "$OPT_LOCAL" ] || die "--local: $OPT_LOCAL is not a directory"
	for p in $EV_PACKAGES; do
		cp "$OPT_LOCAL/${p}_${EV_VERSION}_all.ipk" . 2>/dev/null || die "--local: ${p}_${EV_VERSION}_all.ipk not found in $OPT_LOCAL"
	done
	cp "$OPT_LOCAL/SHA256SUMS" . 2>/dev/null || die "--local: SHA256SUMS not found in $OPT_LOCAL"
else
	command -v wget >/dev/null 2>&1 || die "wget (uclient-fetch) not found"
	say "downloading Easy VLESS ${EV_VERSION} from ${EV_BASE_URL}"
	wget -q -O SHA256SUMS "${EV_BASE_URL}/SHA256SUMS" || die "download failed: ${EV_BASE_URL}/SHA256SUMS"
	for p in $EV_PACKAGES; do
		f="${p}_${EV_VERSION}_all.ipk"
		wget -q -O "$f" "${EV_BASE_URL}/${f}" || die "download failed: ${EV_BASE_URL}/${f}"
	done
fi
for p in $EV_PACKAGES; do
	f="${p}_${EV_VERSION}_all.ipk"
	grep -E "^[0-9a-f]{64}  ${f}\$" SHA256SUMS > "${f}.sha256" || die "${f} is not listed in SHA256SUMS"
	sha256sum -c "${f}.sha256" >/dev/null 2>&1 || die "checksum mismatch for ${f}"
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
	if [ -n "$WANT_SUM" ]; then
		[ "$(sha256sum "$NEW_IPK" | awk '{ print $1 }')" = "$WANT_SUM" ] || die "checksum mismatch for $NEW_IPK - nothing was changed"
	else
		die "the feed index has no SHA256sum for dnsmasq-full - refusing to install an unverified file"
	fi
	OLD_IPK=""
	if [ -n "${DNSMASQ_PKG:-}" ]; then
		opkg download "$DNSMASQ_PKG" >/dev/null || die "opkg download $DNSMASQ_PKG (rollback copy) failed - nothing was changed"
		OLD_IPK="$(ls "${DNSMASQ_PKG}"_*.ipk 2>/dev/null | head -n1)"
		[ -n "$OLD_IPK" ] || die "rollback copy of $DNSMASQ_PKG not found - nothing was changed"
	fi
	DEPS="$(pkg_field dnsmasq-full Depends | tr ',' '\n' | sed 's/([^)]*)//g; s/^[[:space:]]*//; s/[[:space:]].*$//' | grep -v -e '^$' -e '^libc$')"
	if [ -n "$DEPS" ]; then
		# shellcheck disable=SC2086
		opkg install $DEPS || die "installing the dependencies of dnsmasq-full failed - dnsmasq was not changed"
	fi
	cp -p /etc/config/dhcp /etc/config/dhcp.easy-vless.bak 2>/dev/null || die "cannot back up /etc/config/dhcp - nothing was changed"
	if [ -n "${DNSMASQ_PKG:-}" ]; then
		opkg remove "$DNSMASQ_PKG" || die "opkg remove $DNSMASQ_PKG failed"
	fi
	if ! opkg install "./$NEW_IPK"; then
		warn "installing dnsmasq-full failed - restoring ${DNSMASQ_PKG:-dnsmasq}"
		[ -n "$OLD_IPK" ] && opkg install "./$OLD_IPK"
		cp -p /etc/config/dhcp.easy-vless.bak /etc/config/dhcp
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
		die "dnsmasq-full could not be installed; ${DNSMASQ_PKG:-dnsmasq} was restored"
	fi
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
say "installing easy-vless, easy-vless-sing-box, luci-app-easy-vless ${EV_VERSION}${OLD_EV:+ (upgrade from ${OLD_EV})} ..."
IPKS=""
for p in $EV_PACKAGES; do IPKS="$IPKS ./${p}_${EV_VERSION}_all.ipk"; done
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
rm -rf "$WORKDIR"
say "done. Web interface: LuCI -> Services -> Easy VLESS"
