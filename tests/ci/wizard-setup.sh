#!/bin/sh
# Easy VLESS - First Run Wizard tests: prepare an OpenWrt rootfs container
# (CI, called by tests/ci/wizard-tests.sh through "docker exec").
#
#   1. ubusd + rpcd + Easy VLESS from the built packages: the same path as
#      the runtime tests (tests/ci/openwrt-runtime-tests.sh, SKIP_TESTS=1),
#      a fresh installation with the default configuration;
#   2. with WITH_LUCI=1: the LuCI web interface (package "luci") served by
#      uhttpd on port 80 - through procd when procd can run next to the
#      container's init (it then also runs dnsmasq like on a router),
#      otherwise uhttpd started directly with the same options.
# The container has NET_ADMIN (nftables, ip rule) in its own network
# namespace; nothing touches the runner's network.

set -eu
W="${W:-/w}"
DIST="${DIST:-$W/dist}"
say() { echo "[wizard-setup] $*"; }
die() { echo "[wizard-setup] ERROR: $*" >&2; exit 1; }

wait_for() {
	desc="$1"; shift
	i=0
	until "$@" >/dev/null 2>&1; do
		i=$((i + 1))
		[ "$i" -lt 20 ] || return 1
		sleep 1
	done
}

SKIP_TESTS=1 W="$W" DIST="$DIST" sh "$W/tests/ci/openwrt-runtime-tests.sh"

[ "$(uci -q get easy_vless.@global[0].enabled)" = "0" ] || die "fresh installation: main switch is not off"
[ -z "$(uci -q get easy_vless.@global[0].node)" ] || die "fresh installation: a node is already selected"
nft list tables >/dev/null 2>&1 || die "nftables does not work in this container (NET_ADMIN missing?)"
say "nftables usable: $(nft list tables | tr '\n' ' ')"

[ "${WITH_LUCI:-0}" = "1" ] || { say "done (without LuCI)"; exit 0; }

opkg install luci >/tmp/opkg-luci.log 2>&1 || { cat /tmp/opkg-luci.log; die "opkg install luci failed"; }
say "installed: $(opkg list-installed | grep -E '^(luci |luci-base|luci-theme-bootstrap|uhttpd )' | tr '\n' ';')"

uci set uhttpd.main.listen_http='0.0.0.0:80'
uci -q delete uhttpd.main.listen_https || true
uci set uhttpd.main.redirect_https='0'
uci commit uhttpd

# procd as a plain service manager (not PID 1): provides the ubus "service"
# object that the procd init scripts (uhttpd, dnsmasq) need.
if ! ubus -t 1 list service >/dev/null 2>&1; then
	procd >/tmp/procd.log 2>&1 &
	if wait_for "procd service object" ubus -t 1 list service; then
		say "procd running as service manager (pid $!)"
	else
		say "procd did not register the service object; log:"
		cat /tmp/procd.log || true
		kill $! 2>/dev/null || true
	fi
fi

if ubus -t 1 list service >/dev/null 2>&1; then
	/etc/init.d/uhttpd start
	/etc/init.d/dnsmasq start || say "dnsmasq did not start (not needed for the LuCI tests)"
	HOW="procd (/etc/init.d/uhttpd)"
else
	uhttpd -h /www -r OpenWrt -x /cgi-bin -u /ubus -t 60 -T 30 -k 20 -A 1 -n 3 -N 100 -R -p 0.0.0.0:80 >/tmp/uhttpd.log 2>&1 &
	HOW="uhttpd started directly (CGI)"
fi
wait_for "LuCI login page" sh -c 'curl -s http://127.0.0.1/cgi-bin/luci/ | grep -q luci_password' \
	|| { curl -s -i http://127.0.0.1/cgi-bin/luci/ | head -30; cat /tmp/uhttpd.log 2>/dev/null || true; die "LuCI does not answer"; }
say "LuCI answers on port 80 ($HOW)"
