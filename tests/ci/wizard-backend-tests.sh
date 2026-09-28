#!/bin/sh
# Easy VLESS - First Run Wizard: backend tests through ubus (rpcd object
# luci.easy_vless - the calls the LuCI wizard makes), inside an OpenWrt
# rootfs container prepared by tests/ci/wizard-setup.sh (CI).
#
#   GOOD_LINK   vless:// link of a real VLESS server (sing-box in another
#               container, tests/ci/wizard-tests.sh)
#   BAD_LINK    vless:// link to a closed port of that host
#   sh wizard-backend-tests.sh          run the tests
#   sh wizard-backend-tests.sh reset    fresh-install configuration again
#
# Covered: first-run detection, import of valid / invalid links, Server Test
# and URL Test (success and failure), the configuration backup and restore
# around Apply, check + start of the routing the wizard writes, finish, a
# failed start and an invalid configuration (sing-box fault injection),
# a manually configured router.

CONFIG=easy_vless
BACKUP=/etc/easy_vless/wizard-backup
PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
SKIP=0
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $* - nftables (netlink netfilter) is not emulated by QEMU user emulation ($(uname -m)); tested on x86-64"; }
check() { if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }
call() { ubus -t 120 call luci.easy_vless "$1" "${2:-{\}}" 2>&1; }
jget() { jsonfilter -s "$1" -e "$2" 2>/dev/null; }
servers() { uci -q show $CONFIG | grep -c "\.protocol='vless'$"; }

status_wait() { # status_wait running|stopped [seconds]: poll rpcd status
	want="$1"; n="${2:-60}"; i=0
	while [ "$i" -lt "$n" ]; do
		st=$(call status)
		busy=$(jget "$st" '@.busy'); run=$(jget "$st" '@.running')
		if [ "$busy" != "true" ]; then
			[ "$want" = running ] && [ "$run" = "true" ] && return 0
			[ "$want" = stopped ] && [ "$run" != "true" ] && [ "$i" -ge 3 ] && return 0
		fi
		i=$((i + 1)); sleep 1
	done
	return 1
}

reset_config() {
	/etc/init.d/easy_vless stop >/dev/null 2>&1
	cp /usr/share/easy_vless/0_default_config /etc/config/$CONFIG
	uci -q revert $CONFIG
	rm -f "$BACKUP"
}

fault() { # fault run|check|off: sing-box that fails "run" or "check"
	if [ "$1" = off ]; then
		[ -x /usr/bin/sing-box.real ] && mv -f /usr/bin/sing-box.real /usr/bin/sing-box
		return
	fi
	[ -x /usr/bin/sing-box.real ] || mv /usr/bin/sing-box /usr/bin/sing-box.real
	cat >/usr/bin/sing-box <<EOF
#!/bin/sh
[ "\$1" = "$1" ] && { echo "FATAL[0000] fault injected by the wizard tests: sing-box $1 fails" >&2; exit 1; }
exec /usr/bin/sing-box.real "\$@"
EOF
	chmod +x /usr/bin/sing-box
}

if [ "${1:-}" = reset ]; then
	fault off
	reset_config
	echo "configuration reset to the fresh-install default"
	exit 0
fi
if [ "${1:-}" = fault ]; then   # used by the LuCI end-to-end test
	fault "${2:-off}"
	echo "sing-box fault: ${2:-off}"
	exit 0
fi

[ -n "${GOOD_LINK:-}" ] && [ -n "${BAD_LINK:-}" ] || { echo "GOOD_LINK and BAD_LINK are required"; exit 2; }
ubus -t 5 list luci.easy_vless >/dev/null 2>&1 || { echo "ubus object luci.easy_vless missing"; exit 2; }
trap 'fault off' EXIT
NFT=0; [ -s /tmp/ev-nft-ok ] && NFT=1

echo "== fresh installation"
st=$(call wizard_state)
echo "$st"
check "fresh install: wizard needed" '[ "$(jget "$st" @.needed)" = true ]'
check "fresh install: not completed" '[ "$(jget "$st" @.completed)" = false ]'
check "fresh install: no servers" '[ "$(jget "$st" @.servers)" = 0 ]'
check "fresh install: no backup" '[ "$(jget "$st" @.backup)" = false ]'

echo "== invalid links"
for l in "ss://YWVzLTI1Ni1nY206cGFzcw@192.0.2.1:8388#ss" "https://example.com/list" "just some text"; do
	r=$(call import "{\"links\":\"$l\"}")
	check "import refuses a non-VLESS link ($l)" '[ "$(jget "$r" @.added)" = 0 ] && [ "$(jget "$r" @.code)" = 1 ]'
done
for l in "vless://not-a-valid-link" "vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443?type=kcp&security=none#kcp"; do
	r=$(call import "{\"links\":\"$l\"}")
	check "import adds no server for an invalid/unsupported VLESS link ($l)" '[ "$(jget "$r" @.added)" = 0 ]'
done
check "invalid links: still no servers" '[ "$(servers)" = 0 ]'

echo "== valid links"
r=$(call import "{\"links\":\"$GOOD_LINK\"}")
echo "$r"
GOOD=$(jget "$r" '@.nodes[0].id')
check "import of a valid link adds one server" '[ "$(jget "$r" @.added)" = 1 ] && [ -n "$GOOD" ]'
check "imported parameters are returned (address:port of the link)" 'echo "$GOOD_LINK" | grep -qF "@$(jget "$r" @.nodes[0].address):$(jget "$r" @.nodes[0].port)?"'
check "imported parameters: no TLS for security=none" '[ "$(jget "$r" @.nodes[0].tls)" != 1 ]'
check "imported server is a VLESS node in UCI" '[ "$(uci -q get $CONFIG.$GOOD.protocol)" = vless ]'
r=$(call import "{\"links\":\"$BAD_LINK\"}")
BADN=$(jget "$r" '@.nodes[0].id')
check "import of the closed-port link adds one server" '[ "$(jget "$r" @.added)" = 1 ] && [ -n "$BADN" ]'
st=$(call wizard_state)
check "servers added, no node selected: wizard still needed" '[ "$(jget "$st" @.needed)" = true ] && [ "$(jget "$st" @.servers)" = 2 ]'

echo "== Server Test / URL Test"
r=$(call urltest_node "{\"node\":\"$GOOD\"}")
echo "$r"
SOMARK=1
if [ "$(jget "$r" @.ok)" != true ]; then
	# diagnostics: the same temporary instance with a debug log. Under QEMU
	# user emulation setsockopt(SO_MARK) - sing-box "routing_mark", which the
	# router needs so that its own traffic bypasses TPROXY - is not
	# emulated: every dial fails with "protocol not available". Only that
	# exact error counts as an emulation limit; anything else is a failure.
	echo "---- diagnostics of the failed Server Test"
	uci set $CONFIG.@global[0].loglevel='debug'; uci commit $CONFIG
	NO_REC_PROCESS=1 /usr/share/easy_vless/app.sh run_socks flag=diag node="$GOOD" bind=127.0.0.1 socks_port=48999 config_file=diag.json log_file=diag-sb.log
	sleep 5
	curl -s --max-time 8 -o /dev/null -x socks5h://127.0.0.1:48999 https://www.gstatic.com/generate_204
	dlog="$(cat "$(find /tmp/etc -name 'diag-sb.log' | head -n1)" 2>/dev/null)"
	echo "$dlog" | tail -n 12
	busybox pgrep -af "diag" | awk '!/wizard-backend/{print $1}' | xargs -r kill -9
	uci set $CONFIG.@global[0].loglevel='warn'; uci commit $CONFIG
	if [ "$NFT" = 0 ] && echo "$dlog" | grep -q "dial tcp .*: protocol not available"; then
		SOMARK=0
		echo "SKIP: successful Server Test / URL Test - setsockopt(SO_MARK) is not emulated by QEMU user emulation ($(uname -m)): sing-box: $(echo "$dlog" | grep -o 'dial tcp .*: protocol not available' | head -n1); tested on x86-64"
		SKIP=$((SKIP + 2))
	fi
fi
if [ "$SOMARK" = 1 ]; then
	check "Server Test of the working server passes" '[ "$(jget "$r" @.ok)" = true ]'
	check "Server Test: HTTP 204/200 from generate_204" 'case "$(jget "$r" @.http_code)" in 200|204) true ;; *) false ;; esac'
	r=$(call urltest_node "{\"node\":\"$GOOD\",\"url\":\"https://x.com\"}")
	echo "$r"
	check "URL Test (https://x.com) of the working server passes" '[ "$(jget "$r" @.ok)" = true ]'
fi
r=$(call urltest_node "{\"node\":\"$BADN\"}")
echo "$r"
check "Server Test of the closed port fails" '[ "$(jget "$r" @.ok)" = false ]'
check "failed Server Test has a reason" '[ -n "$(jget "$r" @.error)" ]'
r=$(call urltest_node "{\"node\":\"nosuchnode\"}")
check "Server Test of an unknown server is refused" '[ "$(jget "$r" @.ok)" = false ]'
pgrep -f "url_test_" >/dev/null && bad "test instances left running: $(pgrep -af url_test_)" || ok "no temporary test instance left running"

echo "== Apply: backup, routing, check, start, finish"
cp /etc/config/$CONFIG /tmp/wiz-before
r=$(call wizard '{"action":"backup"}')
check "backup ok" '[ "$(jget "$r" @.ok)" = true ]'
check "backup is the committed configuration" 'cmp -s "$BACKUP" /etc/config/$CONFIG'
# the routing the wizard's "Recommended" choice writes (Rule Manage
# prepared rules RUSSIA/PROXY/QUIC/UDP, Main Router targets)
uci -q batch <<EOF
set $CONFIG.RUSSIA=shunt_rules
set $CONFIG.RUSSIA.remarks='RUSSIA'
set $CONFIG.RUSSIA.network='tcp,udp'
add_list $CONFIG.RUSSIA.domain_resource='russia'
set $CONFIG.PROXY=shunt_rules
set $CONFIG.PROXY.remarks='PROXY'
set $CONFIG.PROXY.network='tcp,udp'
add_list $CONFIG.PROXY.domain_resource='proxy'
set $CONFIG.QUIC=shunt_rules
set $CONFIG.QUIC.remarks='QUIC'
set $CONFIG.QUIC.network='udp'
set $CONFIG.QUIC.port='443'
set $CONFIG.UDP=shunt_rules
set $CONFIG.UDP.remarks='UDP'
set $CONFIG.UDP.network='udp'
set $CONFIG.main_router.RUSSIA='_direct'
set $CONFIG.main_router.PROXY='$GOOD'
set $CONFIG.main_router.QUIC='$GOOD'
set $CONFIG.main_router.UDP='$GOOD'
set $CONFIG.main_router.default_node='$GOOD'
set $CONFIG.@global[0].node='main_router'
commit $CONFIG
EOF
r=$(call check)
echo "$r" | head -c 600; echo
check "sing-box check of the wizard routing passes" '[ "$(jget "$r" @.ok)" = true ]'
if [ "$NFT" = 1 ]; then
	r=$(call start)
	check "start accepted" '[ "$(jget "$r" @.ok)" = true ]'
	if status_wait running 60; then ok "service running after start"; else bad "service not running after start"; call status; fi
	st=$(call status)
	check "firewall table present" '[ "$(jget "$st" @.nft_table)" = true ]'
	check "main switch on" '[ "$(uci -q get $CONFIG.@global[0].enabled)" = 1 ]'
	r=$(call wizard '{"action":"connectivity"}')
	echo "connectivity through the running service: $r"
	check "connectivity check from the router through Easy VLESS" '[ "$(jget "$r" @.ok)" = true ]'
else
	skip "service start, firewall table and connectivity"
fi
r=$(call wizard '{"action":"finish"}')
check "finish ok" '[ "$(jget "$r" @.ok)" = true ]'
st=$(call wizard_state)
check "after finish: completed, not needed, no backup" '[ "$(jget "$st" @.completed)" = true ] && [ "$(jget "$st" @.needed)" = false ] && [ ! -e "$BACKUP" ]'

echo "== failed start: restore"
if [ "$NFT" = 1 ]; then
	call stop >/dev/null
	status_wait stopped 60 || bad "service did not stop"
fi
cp /etc/config/$CONFIG /tmp/wiz-committed
r=$(call wizard '{"action":"backup"}')
check "backup before the failing Apply" '[ "$(jget "$r" @.ok)" = true ]'
uci set $CONFIG.@global[0].loglevel='info'; uci commit $CONFIG
if [ "$NFT" = 1 ]; then
	fault run
	r=$(call start)
	check "start: configuration check still passes" '[ "$(jget "$r" @.ok)" = true ]'
	sleep 3
	status_wait stopped 60 && ok "failed start is rolled back (not running)" || bad "failed start: still running/busy"
	st=$(call status)
	check "failed start: no firewall table left" '[ "$(jget "$st" @.nft_table)" = false ]'
else
	skip "failed start (sing-box fault) and its rollback"
	uci set $CONFIG.@global[0].enabled='1'; uci commit $CONFIG
fi
r=$(call wizard '{"action":"restore"}')
echo "$r"
check "restore ok" '[ "$(jget "$r" @.ok)" = true ]'
status_wait stopped 60 || bad "not stopped after restore"
check "restore puts the configuration from before Apply back" 'cmp -s /etc/config/$CONFIG /tmp/wiz-committed'
check "restore removes the backup" '[ ! -e "$BACKUP" ]'
check "restored: main switch off" '[ "$(uci -q get $CONFIG.@global[0].enabled)" = 0 ]'
check "restored: nothing running" '[ "$(jget "$(call status)" @.running)" = false ]'
[ "$NFT" = 1 ] && check "restored: no firewall table" '! nft list table inet easy_vless >/dev/null 2>&1'
r=$(call wizard '{"action":"restore"}')
check "restore without a backup is refused" '[ "$(jget "$r" @.ok)" = false ] && [ -n "$(jget "$r" @.error)" ]'
fault off

echo "== invalid configuration"
fault check
r=$(call check)
check "invalid configuration: check fails with the sing-box message" '[ "$(jget "$r" @.ok)" = false ] && jget "$r" @.output | grep -q "fault injected"'
r=$(call start)
check "invalid configuration: start refused" '[ "$(jget "$r" @.ok)" = false ]'
check "invalid configuration: main switch stays off" '[ "$(uci -q get $CONFIG.@global[0].enabled)" = 0 ]'
sleep 2
st=$(call status)
check "invalid configuration: service not started" '[ "$(jget "$st" @.running)" = false ] && [ "$(jget "$st" @.nft_table)" = false ]'
fault off

echo "== manually configured router"
reset_config
st=$(call wizard_state)
check "reset: wizard needed again" '[ "$(jget "$st" @.needed)" = true ]'
r=$(call import "{\"links\":\"$GOOD_LINK\"}")
id=$(jget "$r" '@.nodes[0].id')
uci set $CONFIG.@global[0].node="$id"; uci commit $CONFIG
st=$(call wizard_state)
check "node selected by hand (main switch off): wizard not needed" '[ "$(jget "$st" @.needed)" = false ] && [ "$(jget "$st" @.node_ok)" = true ]'
uci set $CONFIG.@global[0].node='gone'; uci set $CONFIG.@global[0].enabled='1'; uci commit $CONFIG
st=$(call wizard_state)
check "main switch on by hand: wizard not needed" '[ "$(jget "$st" @.needed)" = false ]'
uci set $CONFIG.@global[0].enabled='0'; uci commit $CONFIG
st=$(call wizard_state)
check "selected node deleted and switch off: wizard needed" '[ "$(jget "$st" @.needed)" = true ] && [ "$(jget "$st" @.node_ok)" = false ]'
uci set $CONFIG.@global[0].wizard_completed='1'; uci commit $CONFIG
st=$(call wizard_state)
check "completed once: never needed again" '[ "$(jget "$st" @.needed)" = false ]'
reset_config

echo
echo "===== wizard backend tests: $PASS passed, $FAIL failed, $SKIP skipped (QEMU emulation limits) ====="
[ "$FAIL" -eq 0 ]
