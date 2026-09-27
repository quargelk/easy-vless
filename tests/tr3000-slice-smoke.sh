#!/bin/sh
# Easy VLESS - smoke test for a real OpenWrt router (TR3000 / WR3000E).
# Not installed by any package; copy to the router and run as root:
#   sh tr3000-slice-smoke.sh [<server section id>]
#
# Preconditions: easy-vless, easy-vless-sing-box, luci-app-easy-vless and a
# package providing "sing-box" (sing-box-tiny 1.12.22) are installed,
# dnsmasq-full is installed, and at least one working VLESS server exists
# (LuCI: Services -> Easy VLESS -> Node List, "Import VLESS URL").
#
# Safety: arms a 5-minute rollback timer (stop + firewall restart) before
# starting Easy VLESS and disarms it only if every check passed.

CONFIG=easy_vless
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
info() { echo "----- $* -----"; }
procs() { pgrep -f "/tmp/etc/${CONFIG}/bin/sing-box" | wc -l; }
clean_state() {
	pgrep -f "/tmp/etc/${CONFIG}/" >/dev/null && bad "$1: processes left: $(pgrep -af "/tmp/etc/${CONFIG}/")" || ok "$1: no Easy VLESS processes left"
	nft list table inet ${CONFIG} >/dev/null 2>&1 && bad "$1: nft table inet ${CONFIG} still present" || ok "$1: nft table removed"
	ip rule | grep -q 'lookup 998' && bad "$1: ip rule 998 still present" || ok "$1: ip rule 998 removed"
	[ -z "$(ip route show table 998 2>/dev/null)" ] && ok "$1: route table 998 empty" || bad "$1: route table 998 not empty"
	[ -e /var/run/${CONFIG}.pid ] && bad "$1: PID file still present" || ok "$1: PID file removed"
}
running_state() {
	local pid=$(cat /var/run/${CONFIG}.pid 2>/dev/null)
	if [ -n "$pid" ] && tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | grep -q "/tmp/etc/${CONFIG}/"; then
		ok "$1: PID $pid ($(tr '\0' ' ' < /proc/$pid/cmdline)) $(grep -E 'VmRSS|VmHWM' /proc/$pid/status | tr -s ' \n' ' ')"
	else
		bad "$1: no valid PID file / sing-box process"
	fi
	[ "$(procs)" = 1 ] && ok "$1: exactly one sing-box process" || bad "$1: sing-box process count $(procs)"
	nft list table inet ${CONFIG} >/dev/null 2>&1 && ok "$1: nft table present" || bad "$1: nft table missing"
	ip rule | grep -q 'lookup 998' && ok "$1: ip rule 998 present" || bad "$1: ip rule 998 missing"
}

info "Environment"
grep -E 'DISTRIB_(RELEASE|TARGET|ARCH)' /etc/openwrt_release 2>/dev/null
opkg list-installed | grep -E '^(easy-vless|luci-app-easy-vless|sing-box|dnsmasq|geoview|v2ray-geo)'
free | head -2
df -h /overlay 2>/dev/null | tail -1
sing-box version | head -2

info "Preconditions"
dnsmasq --help 2>/dev/null | grep -q -- '--nftset' && ok "dnsmasq supports --nftset" \
	|| bad "dnsmasq has no --nftset (install dnsmasq-full manually; Easy VLESS never does it)"
ubus list luci.easy_vless >/dev/null 2>&1 && ok "ubus object luci.easy_vless registered" || bad "ubus object luci.easy_vless missing"
# LuCI saves with ubus "uci commit"; luci-base does not grant it (0.4.0 fix).
grep -q '"commit"' /usr/share/rpcd/acl.d/luci-app-easy-vless.json 2>/dev/null && ok "ACL grants ubus uci commit (LuCI Save/Check/Start)" || bad "ACL lacks ubus uci commit: LuCI saves fail silently"
NODE=${1:-$(uci -q get ${CONFIG}.@global[0].node)}
[ "$NODE" = "main_router" ] && NODE=$(uci -q get ${CONFIG}.main_router.default_node)
if [ -z "$NODE" ] || [ "$(uci -q get ${CONFIG}.${NODE}.protocol)" != "vless" ]; then
	NODE=$(uci -q show ${CONFIG} | grep "\.protocol='vless'" | head -n1 | cut -d. -f2)
fi
[ -n "$NODE" ] && ok "test server: $NODE ($(uci -q get ${CONFIG}.${NODE}.remarks))" || { bad "no VLESS server configured"; exit 1; }
OLD_NODE=$(uci -q get ${CONFIG}.@global[0].node)
uci set ${CONFIG}.@global[0].node="$NODE"
uci commit ${CONFIG}

info "Per-server URL test (temporary sing-box instance, service stopped)"
ubus call luci.easy_vless urltest_node "{\"node\":\"$NODE\"}"

info "Config generation + sing-box check (no network changes)"
/usr/share/easy_vless/app.sh check && ok "app.sh check" || bad "app.sh check"
grep -q clash_api /tmp/etc/${CONFIG}_check/config.json && ok "generated config contains experimental.clash_api" || bad "clash_api missing in config"

info "Arming 5 minute rollback timer"
( sleep 300; /etc/init.d/easy_vless stop; /etc/init.d/firewall restart; logger -t easy_vless "smoke test rollback fired" ) >/dev/null 2>&1 &
ROLLBACK_PID=$!

info "1. Start via rpcd (same path as the LuCI button)"
ubus call luci.easy_vless start
sleep 12
running_state "start"
IP_PROXY=$(curl -s -m 10 https://ifconfig.me 2>/dev/null)
echo "public IP while running: ${IP_PROXY:-<none>}"
[ -n "$IP_PROXY" ] && ok "HTTPS works while running" || bad "HTTPS failed while running"
nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1 && ok "DNS through dnsmasq works" || bad "DNS through dnsmasq failed"

info "2. Clash API"
[ -s /tmp/etc/${CONFIG}/clash_api ] && ok "Clash API state file present" || bad "Clash API state file missing"
ubus call luci.easy_vless groups

info "3. Per-server URL test while running"
ubus call luci.easy_vless urltest_node "{\"node\":\"$NODE\"}"

info "4. Restart (Apply & Start while running)"
ubus call luci.easy_vless start >/dev/null
sleep 14
running_state "restart"

info "5. Stop"
ubus call luci.easy_vless stop >/dev/null
sleep 8
clean_state "stop"
pgrep -x dnsmasq >/dev/null && ok "system dnsmasq running" || bad "system dnsmasq not running"
IP_DIRECT=$(curl -s -m 10 https://ifconfig.me 2>/dev/null)
echo "public IP after stop: ${IP_DIRECT:-<none>}"
[ -n "$IP_DIRECT" ] && ok "direct internet works after stop" || bad "no internet after stop"

info "6. Start again after stop, then kill sing-box and stop (crash cleanup)"
ubus call luci.easy_vless start >/dev/null
sleep 12
running_state "second start"
kill -9 "$(cat /var/run/${CONFIG}.pid 2>/dev/null)" 2>/dev/null
ubus call luci.easy_vless stop >/dev/null
sleep 8
clean_state "stop after crash"

uci set ${CONFIG}.@global[0].node="$OLD_NODE"
uci commit ${CONFIG}

info "Result: $PASS passed, $FAIL failed"
if [ "$FAIL" = 0 ]; then
	kill "$ROLLBACK_PID" 2>/dev/null
	pkill -P "$ROLLBACK_PID" sleep 2>/dev/null
	echo "rollback timer disarmed"
else
	echo "rollback timer left armed (fires 5 minutes after start)"
fi
echo "Log tail:"
tail -n 30 /tmp/log/${CONFIG}.log 2>/dev/null
