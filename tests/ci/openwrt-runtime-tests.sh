#!/bin/sh
# Easy VLESS - runtime tests inside an OpenWrt rootfs container (CI).
#
#   docker run --rm -v "$PWD:/w" openwrt/rootfs:x86-64-24.10.3 \
#       /bin/ash /w/tests/ci/openwrt-runtime-tests.sh
#
# An OpenWrt rootfs container is not a booted OpenWrt system: procd is not
# PID 1, so the services it normally starts at boot are missing. The Easy
# VLESS Lua layer (api.lua -> luci.model.uci) reads and writes UCI through
# ubus, via the "uci" object that rpcd registers on the bus:
#   - without ubusd:  "Unable to establish ubus connection" (luci/util.lua);
#   - with ubusd but without rpcd: every UCI read through luci.model.uci
#     returns nothing, so subscription updates see 0 nodes.
# This script starts exactly these two services (no procd, no init system),
# verifies them, installs Easy VLESS with the release installer and runs the
# existing test suite unchanged. Any failure stops the script (set -e).
#
# Environment: W (repository, default /w), DIST (built packages, default
# $W/dist), LIBUBUS_DIRS (where libubus is searched, default "/lib /usr/lib"),
# SKIP_INSTALL=1 (Easy VLESS already installed: skip install.sh), SKIP_TESTS=1
# (stop after the post-install checks; the caller runs its own tests).

set -eu
W="${W:-/w}"
DIST="${DIST:-$W/dist}"
LIBUBUS_DIRS="${LIBUBUS_DIRS:-/lib /usr/lib}"

say() { echo "[runtime-tests] $*"; }
die() { echo "[runtime-tests] ERROR: $*" >&2; exit 1; }

# wait_for DESCRIPTION COMMAND...: retry for up to 15 s (whole seconds:
# BusyBox sleep in the rootfs image rejects fractions)
wait_for() {
	desc="$1"; shift
	i=0
	until "$@" >/dev/null 2>&1; do
		i=$((i + 1))
		[ "$i" -lt 15 ] || die "timeout waiting for $desc"
		sleep 1
	done
}

# strings of a binary that look like a ubus socket path: every byte outside
# a plain ASCII path character set becomes a newline (only literal ranges,
# no character classes, so it behaves the same in BusyBox and GNU tr)
sock_strings() {
	tr -c 'A-Za-z0-9/._-' '\n' < "$1" | grep -E '^/[A-Za-z0-9/._-]*ubus[A-Za-z0-9/._-]*\.sock$' | sort -u
}

# ---------------------------------------------------------------- 1. tools
# (lua is not part of the rootfs image: it is installed as a dependency of
# easy-vless and checked after the installation)
for t in ubusd ubus uci; do
	command -v "$t" >/dev/null 2>&1 || die "$t not found in this rootfs"
done
if [ "${SKIP_INSTALL:-0}" != "1" ] || ! command -v rpcd >/dev/null 2>&1; then
	command -v opkg >/dev/null 2>&1 || die "opkg not found in this rootfs"
fi

# ---------------------------------------------------------------- 2. socket path
# The socket path is compiled into libubus (used by every client, including
# the Lua binding behind luci.model.uci) and into ubusd; read it from both
# binaries instead of assuming it.
LIBUBUS=""
for d in $LIBUBUS_DIRS; do
	for f in "$d"/libubus.so*; do
		if [ -f "$f" ]; then LIBUBUS="$f"; break 2; fi
	done
done
[ -n "$LIBUBUS" ] || die "libubus.so not found in: $LIBUBUS_DIRS"
SOCK_LIB="$(sock_strings "$LIBUBUS")"
SOCK_D="$(sock_strings "$(command -v ubusd)")"
say "libubus: $LIBUBUS, compiled-in socket: ${SOCK_LIB:-none}"
say "ubusd compiled-in socket: ${SOCK_D:-none}"
[ -n "$SOCK_LIB" ] || die "no socket path found in $LIBUBUS"
[ "$(echo "$SOCK_LIB" | wc -l)" -eq 1 ] || die "several socket paths in $LIBUBUS: $SOCK_LIB"
[ "$SOCK_LIB" = "$SOCK_D" ] || die "libubus ($SOCK_LIB) and ubusd ($SOCK_D) disagree on the socket path"
SOCK="$SOCK_LIB"

# ---------------------------------------------------------------- 3. runtime dirs
# normally created at boot (/var is a symlink to /tmp in OpenWrt)
mkdir -p "$(dirname "$SOCK")" /var/lock /var/state /tmp/log /tmp/.uci

# ---------------------------------------------------------------- 4. ubusd
if ubus -t 1 list >/dev/null 2>&1; then
	say "ubusd already running"
else
	rm -f "$SOCK"
	ubusd -s "$SOCK" &
	wait_for "socket $SOCK" test -S "$SOCK"
	# no -s: the client must reach ubusd through its compiled-in default path
	wait_for "ubusd answering on the default socket" ubus -t 1 list
	say "ubusd started (pid $!) on $SOCK"
fi

# ---------------------------------------------------------------- 5. rpcd
# rpcd registers the "uci" and "session" objects used by luci.model.uci;
# installed only when missing, with ubusd already up for its postinst.
if ! command -v rpcd >/dev/null 2>&1; then
	opkg update
	opkg install rpcd
fi
if ubus -t 1 list uci >/dev/null 2>&1; then
	say "rpcd already running"
else
	rpcd -s "$SOCK" &
	wait_for "rpcd uci object" ubus -t 1 list uci
	say "rpcd started (pid $!)"
fi

# ---------------------------------------------------------------- 6. checks before install
say "check: ubus -t 5 list"
ubus -t 5 list
say "check: uci show"
uci show >/tmp/ev-uci-before.txt
say "uci show: $(wc -l < /tmp/ev-uci-before.txt) lines"
say "check: ubus -t 5 call uci configs"
ubus -t 5 call uci configs

# ---------------------------------------------------------------- 7. install
if [ "${SKIP_INSTALL:-0}" != "1" ]; then
	opkg update
	command -v fw4 >/dev/null 2>&1 || opkg install firewall4
	sh "$W/scripts/install.sh" --check --local "$DIST"
	sh "$W/scripts/install.sh" --local "$DIST" --replace-dnsmasq --yes --no-start
fi

# ---------------------------------------------------------------- 8. checks after install
say "check: ubus -t 5 list"
ubus -t 5 list
ubus -t 5 list uci >/dev/null || die "the uci ubus object is gone after the installation"
say "check: uci show"
uci show >/tmp/ev-uci-after.txt
say "uci show: $(wc -l < /tmp/ev-uci-after.txt) lines"
say "check: uci show easy_vless.global"
uci show easy_vless.global
say "check: ubus -t 5 call uci get easy_vless.global (through rpcd)"
ubus -t 5 call uci get '{"config":"easy_vless","section":"global"}'

# the Lua layer (api.lua -> luci.model.uci -> ubus -> rpcd) must read the
# same configuration as the uci CLI; no assumption about existing nodes -
# the subscription tests create their own
cli_type="$(uci -q get easy_vless.global)" || die "section easy_vless.global is missing"
cli_enabled="$(uci -q get easy_vless.global.enabled)" || die "option easy_vless.global.enabled is missing"
cli_global="${cli_type}=${cli_enabled}"
command -v lua >/dev/null 2>&1 || die "lua not found after the installation of easy-vless"
lua_global="$(lua -e 'local api = require "luci.easy_vless.api"
	print((api.uci:get("easy_vless", "global") or "") .. "=" .. (api.uci:get("easy_vless", "global", "enabled") or ""))')"
say "easy_vless.global (type=enabled): uci CLI '${cli_global}', luci.model.uci '${lua_global}'"
[ "$cli_global" = "$lua_global" ] || die "luci.model.uci does not read /etc/config/easy_vless like the uci CLI"

# ---------------------------------------------------------------- 9. tests
# SKIP_TESTS=1: only prepare the container (tests/ci/wizard-setup.sh)
[ "${SKIP_TESTS:-0}" != "1" ] || { say "SKIP_TESTS=1: setup done, tests not run here"; exit 0; }
cd "$W/tests"
sh subscription-formats-test.sh
