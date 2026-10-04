#!/bin/sh
# Easy VLESS 0.9 - backend tests through ubus (rpcd object luci.easy_vless),
# inside the OpenWrt rootfs container of tests/ci/wizard-tests.sh, after
# wizard-backend-tests.sh (same container, same VLESS test server).
#
#   GOOD_LINK   vless:// link of the real VLESS test server
#   BAD_LINK    vless:// link to a closed port of that host
#   SUB_URL     subscription test server (optional: update races)
#
# Covered: Route Explain on the configuration sing-box really gets (saved
# settings while stopped, the running configuration while running), DNS,
# forwarding and connection diagnostics, concurrency of the diagnostics with
# start / stop / check / Server Test / subscription update (the 0.7.2 class
# of bugs: nothing killed, no empty configuration, no stuck operation),
# deleting servers and "Delete all nodes", Backup / Restore / Import /
# Export with validation, the update method.

. /usr/share/libubox/jshn.sh

CONFIG=easy_vless
APP=/usr/share/easy_vless/app.sh
PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $* - nftables (netlink netfilter) is not emulated by QEMU user emulation ($(uname -m)); tested on x86-64"; }
check() { if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }
call() { ubus -t 120 call luci.easy_vless "$1" "${2:-{\}}" 2>&1; }
jget() { jsonfilter -s "$1" -e "$2" 2>/dev/null; }
# req KEY VALUE ...: a JSON request object with string values (any content)
req() {
	json_init
	while [ $# -ge 2 ]; do json_add_string "$1" "$2"; shift 2; done
	json_dump
}
diag() { call diag "$(req action "$1" arg "${2:-}")"; }
explain() { diag explain "$1"; }
nodes() { call nodes "$(req action "$1" id "${2:-}" key "${3:-}")"; }
transfer() { call transfer "$(req action "$1" data "${2:-}" kind "${3:-}")"; }
servers() { uci -q show $CONFIG | grep -c "\.protocol='vless'$"; }
cfg_sum() { uci -q show $CONFIG | sort | md5sum | cut -d' ' -f1; }
leftovers() { ls -d /tmp/${CONFIG}_diag.* /tmp/${CONFIG}_restore.* /tmp/${CONFIG}_hash.* 2>/dev/null | grep -c .; }

status_wait() { # status_wait running|stopped [seconds]
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
	rm -rf /etc/easy_vless/restore-backup
}

# the routing the First Run Wizard writes for server $1
wizard_routing() {
	uci -q batch <<-EOF
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
		set $CONFIG.main_router.PROXY='$1'
		set $CONFIG.main_router.QUIC='$1'
		set $CONFIG.main_router.UDP='$1'
		set $CONFIG.main_router.default_node='$1'
		set $CONFIG.@global[0].node='main_router'
		commit $CONFIG
	EOF
}

[ -n "${GOOD_LINK:-}" ] && [ -n "${BAD_LINK:-}" ] || { echo "GOOD_LINK and BAD_LINK are required"; exit 2; }
ubus -t 5 list luci.easy_vless >/dev/null 2>&1 || { echo "ubus object luci.easy_vless missing"; exit 2; }
NFT=0; [ -s /tmp/ev-nft-ok ] && NFT=1

echo "== setup: two servers, the wizard routing on the first one"
reset_config
r=$(call import "$(req links "$GOOD_LINK")"); GOOD=$(jget "$r" '@.nodes[0].id')
r=$(call import "$(req links "$BAD_LINK")"); BADN=$(jget "$r" '@.nodes[0].id')
check "two servers imported" '[ -n "$GOOD" ] && [ -n "$BADN" ] && [ "$(servers)" = 2 ]'
wizard_routing "$GOOD"
r=$(call check)
check "the configuration is valid" '[ "$(jget "$r" @.ok)" = true ]'

echo "== settings and names are data, not shell code (1.0)"
rm -f /tmp/ev10-pwned*
SAVED_DOH=$(uci -q get $CONFIG.@global[0].remote_dns_doh)
SAVED_DNS=$(uci -q get $CONFIG.@global[0].remote_dns)
SAVED_HOSTS=$(uci -q get $CONFIG.@global[0].dns_hosts)
uci set $CONFIG.@global[0].remote_dns_doh='https://1.1.1.1/dns-query;touch${IFS}/tmp/ev10-pwned-doh'
uci set $CONFIG.@global[0].remote_dns="1.1.1.1') os.execute('touch /tmp/ev10-pwned-lua') --"
uci set $CONFIG.@global[0].dns_hosts='example.invalid 192.0.2.1; touch /tmp/ev10-pwned-hosts'
uci commit $CONFIG
r=$(call check)
check "check with hostile DNS settings: an answer, nothing was run" '[ -n "$(jget "$r" @.code)" ] && [ -z "$(ls /tmp/ev10-pwned* 2>/dev/null)" ]'
r=$(explain '{"input":"yandex.ru"}')
check "Route Explain with hostile DNS settings: nothing was run" '[ -z "$(ls /tmp/ev10-pwned* 2>/dev/null)" ]'
if [ -n "$SAVED_DOH" ]; then uci set $CONFIG.@global[0].remote_dns_doh="$SAVED_DOH"; else uci -q delete $CONFIG.@global[0].remote_dns_doh; fi
if [ -n "$SAVED_DNS" ]; then uci set $CONFIG.@global[0].remote_dns="$SAVED_DNS"; else uci -q delete $CONFIG.@global[0].remote_dns; fi
# a line of DNS hosts is read as "<domain> <address>", the rest is ignored
uci set $CONFIG.@global[0].dns_hosts='example.invalid 192.0.2.1'
uci commit $CONFIG
r=$(call check)
check "DNS hosts: a valid configuration" '[ "$(jget "$r" @.ok)" = true ]'
check "DNS hosts: the entry is in the generated configuration" 'grep -q "\"example.invalid\": *\"192.0.2.1\"" /tmp/etc/${CONFIG}_check/config.json'
if [ -n "$SAVED_HOSTS" ]; then uci set $CONFIG.@global[0].dns_hosts="$SAVED_HOSTS"; else uci -q delete $CONFIG.@global[0].dns_hosts; fi
uci commit $CONFIG
for bad_id in 'x;touch /tmp/ev10-pwned-id' '$(touch /tmp/ev10-pwned-id)' 'a b' '../x'; do
	call check "$(req node "$bad_id")" >/dev/null
	call urltest_node "$(req node "$bad_id")" >/dev/null
	call group_test "$(req group "$bad_id")" >/dev/null
	call subscribe "$(req action update id "$bad_id")" >/dev/null
	call subscribe "$(req action truncate id "$bad_id")" >/dev/null
done
check "ids that are not section names are refused, nothing was run" '[ -z "$(ls /tmp/ev10-pwned* 2>/dev/null)" ]'
r=$(call check "$(req node 'x;y')")
check "check of an invalid node id: a clear refusal" '[ "$(jget "$r" @.ok)" = false ] && [ "$(jget "$r" @.output)" = "Unknown node." ]'
r=$(call check)
check "the configuration is still valid" '[ "$(jget "$r" @.ok)" = true ]'

echo "== Route Explain: stopped - the configuration the saved settings generate"
r=$(explain '{"input":"www.googlevideo.com"}')
echo "$r" | cut -c1-600
check "explain answers" '[ "$(jget "$r" @.ok)" = true ]'
check "explain: based on the saved settings while stopped" '[ "$(jget "$r" @.config.source)" = saved ]'
check "explain googlevideo.com: the PROXY rule, priority 2" '[ "$(jget "$r" @.route.match.rule_id)" = PROXY ] && [ "$(jget "$r" @.route.match.priority)" = 2 ] && [ "$(jget "$r" @.route.match.rule_name)" = PROXY ]'
check "explain: the reason is the entry of the PROXY resource" '[ "$(jget "$r" "@.route.match.reasons[0].code")" = domain_keyword ] && [ "$(jget "$r" "@.route.match.reasons[0].origin.id")" = proxy ]'
check "explain: the target is the selected server, by id and name" '[ "$(jget "$r" @.route.match.target.kind)" = server ] && [ "$(jget "$r" @.route.match.target.id)" = "$GOOD" ] && [ -n "$(jget "$r" @.route.match.target.name)" ]'
check "explain: the rule above was checked and skipped" '[ "$(jget "$r" "@.route.skipped[0].rule_id")" = RUSSIA ]'
check "explain: certain" '[ "$(jget "$r" @.route.certain)" = true ]'
check "explain: DNS and forwarding are part of the answer" '[ -n "$(jget "$r" @.dns.a.match.action)" ] && [ "$(jget "$r" @.intercept.intercepted)" = yes ] && [ "$(jget "$r" @.intercept.method)" = tproxy ]'
r=$(explain '{"input":"yandex.ru"}')
check "explain yandex.ru: RUSSIA -> Direct, DNS = Direct DNS" '[ "$(jget "$r" @.route.match.rule_id)" = RUSSIA ] && [ "$(jget "$r" @.route.match.target.kind)" = direct ] && [ "$(jget "$r" @.dns.a.match.server.kind)" = direct ]'
r=$(explain '{"input":"example.org"}')
check "explain example.org: no rule, Default -> the server" '[ "$(jget "$r" @.route.match.kind)" = default ] && [ "$(jget "$r" @.route.match.target.id)" = "$GOOD" ]'
r=$(explain '{"input":"example.org","network":"udp"}')
check "explain example.org over UDP 443: the QUIC rule" '[ "$(jget "$r" @.route.match.rule_id)" = QUIC ]'
r=$(explain '{"input":"example.org:3478","network":"udp"}')
check "explain host:port over UDP: the UDP rule" '[ "$(jget "$r" @.route.match.rule_id)" = UDP ] && [ "$(jget "$r" @.input.port)" = 3478 ]'
r=$(explain '{"input":"https://www.googlevideo.com/videoplayback?x=1"}')
check "explain a URL" '[ "$(jget "$r" @.route.match.rule_id)" = PROXY ] && [ "$(jget "$r" @.input.port)" = 443 ]'
r=$(explain '{"input":"8.8.8.8"}')
check "explain an IP address: Default (domain rules need a name)" '[ "$(jget "$r" @.input.kind)" = ip ] && [ "$(jget "$r" @.route.match.kind)" = default ]'
r=$(explain '{"input":"192.168.1.10"}')
check "explain a LAN address: not intercepted" '[ "$(jget "$r" @.intercept.intercepted)" = no ]'
# the target follows the settings: PROXY -> the other server
uci set $CONFIG.main_router.PROXY="$BADN"; uci commit $CONFIG
r=$(explain '{"input":"www.googlevideo.com"}')
check "explain follows a changed rule target" '[ "$(jget "$r" @.route.match.target.id)" = "$BADN" ]'
uci set $CONFIG.main_router.PROXY='_blackhole'; uci commit $CONFIG
r=$(explain '{"input":"www.googlevideo.com"}')
check "explain: target Block" '[ "$(jget "$r" @.route.match.target.kind)" = block ]'
uci set $CONFIG.main_router.PROXY="$GOOD"; uci commit $CONFIG
# the order decides
uci reorder $CONFIG.PROXY=0; uci commit $CONFIG
r=$(explain '{"input":"www.googlevideo.com"}')
check "explain follows the rule order (PROXY first: priority 1)" '[ "$(jget "$r" @.route.match.priority)" = 1 ]'
uci reorder $CONFIG.RUSSIA=0; uci commit $CONFIG
r=$(explain '{"input":"not a host"}')
check "explain: invalid input is refused with its reason" '[ "$(jget "$r" @.ok)" = false ] && [ "$(jget "$r" @.error)" = input ] && [ -n "$(jget "$r" @.reason)" ]'
rm -f /tmp/ev09-pwned
r=$(explain '{"input":"$(touch /tmp/ev09-pwned)"}')
r=$(diag dns '`touch /tmp/ev09-pwned`')
r=$(diag dns "x'; touch /tmp/ev09-pwned; '")
check "input with shell characters is refused and never executed" '[ ! -e /tmp/ev09-pwned ] && [ "$(jget "$r" @.ok)" = false ]'
r=$(diag nosuch)
check "unknown diagnostic action" '[ "$(jget "$r" @.ok)" = false ]'
check "no temporary copies of the configuration left" '[ "$(leftovers)" = 0 ]'
uci set $CONFIG.@global[0].node=''; uci commit $CONFIG
r=$(explain '{"input":"example.org"}')
check "explain without a selected node: the reason of the router, not a guess" '[ "$(jget "$r" @.ok)" = false ] && [ "$(jget "$r" @.error)" = config ] && jget "$r" @.detail | grep -qi "node"'
uci set $CONFIG.@global[0].node='main_router'; uci commit $CONFIG

echo "== diagnostics while stopped"
r=$(diag forwarding)
echo "$r" | cut -c1-400
if [ "$NFT" = 1 ]; then
	check "forwarding (stopped): 'off', not a failure" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" @.status)" = off ] && [ "$(jget "$r" "@.groups.nftables.checks[1].code")" = stopped ]'
else
	check "forwarding without a usable nft: reported as such, not as 'stopped'" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" "@.groups.nftables.checks[0].status")" = fail ]'
fi
r=$(diag connection)
check "connection (stopped): seven items" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" "@.items[*].id" | tr "\n" " ")" = "core dns nftables tproxy vless routing internet " ]'
check "connection (stopped): the service item says 'switched off'" 'jget "$r" "@.items[0].checks[*].code" | grep -qx switched_off'
check "connection (stopped): the selected server is named" 'jget "$r" "@.items[4].checks[*].code" | grep -qx node_server'
check "connection (stopped): targets are consistent" 'jget "$r" "@.items[5].checks[*].code" | grep -qx references_ok'
r=$(diag dns example.org)
check "DNS (stopped): the router's own DNS is checked" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" @.running)" = false ] && [ "$(jget "$r" "@.checks[0].code")" = dns_stopped ]'

echo "== concurrency: diagnostics and Route Explain against check / stop (stopped service)"
RACE=/tmp/ev09-race
# two explains at once: both generate through the same check directory
( explain '{"input":"yandex.ru"}' >$RACE.1 ) &
p1=$!
( explain '{"input":"www.googlevideo.com"}' >$RACE.2 ) &
p2=$!
wait "$p1" "$p2"
check "two Route Explain requests at once: both answer correctly" '[ "$(jget "$(cat $RACE.1)" @.route.match.rule_id)" = RUSSIA ] && [ "$(jget "$(cat $RACE.2)" @.route.match.rule_id)" = PROXY ]'
# explain while a configuration check runs, and while a stop runs
( $APP check >$RACE.check 2>&1; echo $? >$RACE.rc ) &
pc=$!
r=$(explain '{"input":"yandex.ru"}')
wait "$pc"
check "Route Explain during a configuration check: both succeed" '[ "$(jget "$r" @.route.match.rule_id)" = RUSSIA ] && [ "$(cat $RACE.rc)" = 0 ] && ! grep -qE "Killed|decode config|Broken pipe" $RACE.check'
( explain '{"input":"yandex.ru"}' >$RACE.1 ) &
p1=$!
$APP stop >/dev/null 2>&1
wait "$p1"
r=$(cat $RACE.1)
check "Route Explain during app.sh stop: a correct answer or 'busy', never an empty or broken one" '[ "$(jget "$r" @.route.match.rule_id)" = RUSSIA ] || [ "$(jget "$r" @.error)" = busy ]'
( diag connection >$RACE.1 ) &
p1=$!
$APP stop >/dev/null 2>&1
wait "$p1"
check "connection diagnostics during app.sh stop: not killed, a complete answer" '[ "$(jget "$(cat $RACE.1)" @.ok)" = true ] && [ "$(jget "$(cat $RACE.1)" "@.items[6].id")" = internet ]'
# a held operation lock: the diagnostic reports busy instead of waiting for ever
( exec 7>>/var/lock/${CONFIG}_op.lock; flock -x 7; exec sleep 25 ) &
ph=$!
sleep 1
t0=$(date +%s)
r=$(EV_DIAG_LOCK_WAIT=3 lua /usr/share/easy_vless/diag.lua explain '{"input":"yandex.ru"}')
t1=$(date +%s)
check "operation lock held by another operation: 'busy' after a short wait ($((t1 - t0)) s), no deadlock" '[ "$(jget "$r" @.error)" = busy ] && [ "$((t1 - t0))" -lt 15 ]'
r=$(diag dns example.org)
check "read-only diagnostics do not need the lock" '[ "$(jget "$r" @.ok)" = true ]'
kill "$ph" 2>/dev/null; wait "$ph" 2>/dev/null
r=$(explain '{"input":"yandex.ru"}')
check "after the lock is free again: Route Explain works" '[ "$(jget "$r" @.route.match.rule_id)" = RUSSIA ]'
check "no waiting markers and no temporary copies left" '[ -z "$(ls /var/lock/${CONFIG}_op.lock.wait.* 2>/dev/null)" ] && [ "$(leftovers)" = 0 ]'

if [ "$NFT" = 1 ]; then
	echo "== running service"
	r=$(call start)
	check "start accepted" '[ "$(jget "$r" @.ok)" = true ]'
	# a diagnostic right into the start
	r=$(diag connection)
	check "connection diagnostics during the start: an answer, marked busy or already running" '[ "$(jget "$r" @.ok)" = true ]'
	if status_wait running 60; then ok "service running"; else bad "service not running"; call status; fi
	r=$(explain '{"input":"www.googlevideo.com"}')
	check "explain (running): based on the running configuration, same rule and server" '[ "$(jget "$r" @.config.source)" = running ] && [ "$(jget "$r" @.route.match.rule_id)" = PROXY ] && [ "$(jget "$r" @.route.match.target.id)" = "$GOOD" ]'
	# a saved but not applied change is not what runs
	uci set $CONFIG.main_router.PROXY='_direct'; uci commit $CONFIG
	sleep 1
	if status_wait running 60; then
		r=$(explain '{"input":"www.googlevideo.com"}')
		echo "explain after an unapplied change: source $(jget "$r" @.config.source), target $(jget "$r" @.route.match.target.kind)"
	fi
	uci set $CONFIG.main_router.PROXY="$GOOD"; uci commit $CONFIG
	call start >/dev/null; status_wait running 60 || bad "service not running after the restart"

	r=$(diag forwarding)
	echo "$r"
	codes() { jget "$r" "@.groups.$1.checks[*].code" | tr '\n' ' '; }
	check "forwarding: table, chains and sets found ($(codes nftables))" 'codes nftables | grep -q table_ok && codes nftables | grep -q chains_ok && ! codes nftables | grep -q missing'
	check "forwarding: policy routing found ($(codes tproxy))" 'codes tproxy | grep -q policy_ok'
	check "forwarding: TCP and UDP redirected, LAN and router intercepted" '[ "$(jget "$r" @.tcp)" = ok ] && [ "$(jget "$r" @.udp)" = ok ] && codes tproxy | grep -q lan_ok && codes tproxy | grep -q router_ok'
	check "forwarding: no failed check" '[ "$(jget "$r" @.status)" != fail ]'
	# break it for real: the diagnostics must name what is missing
	ip rule del fwmark 0x45560000 2>/dev/null
	r=$(diag forwarding)
	check "ip rule removed: policy routing fails with its reason" 'codes tproxy | grep -q policy_rule_missing && [ "$(jget "$r" @.groups.tproxy.status)" = fail ]'
	ip rule add fwmark 0x45560000 table 998 priority 998 2>/dev/null
	hs=$(nft -a list chain inet $CONFIG EV_MANGLE 2>/dev/null | grep "udp" | grep "tproxy" | sed -n 's/.*# handle \([0-9]*\).*/\1/p')
	if [ -n "$hs" ]; then
		for h in $hs; do nft delete rule inet $CONFIG EV_MANGLE handle "$h"; done
		r=$(diag forwarding)
		check "UDP TPROXY rule removed: UDP fails, TCP still works - partly working" '[ "$(jget "$r" @.udp)" = fail ] && [ "$(jget "$r" @.tcp)" = ok ] && [ "$(jget "$r" @.groups.tproxy.partial)" = true ]'
	else
		bad "no UDP TPROXY rule found in EV_MANGLE"
	fi
	call start >/dev/null; status_wait running 60 || bad "service not running after the restart"
	r=$(diag forwarding)
	check "after a restart everything is back" '[ "$(jget "$r" @.status)" != fail ]'

	r=$(diag dns www.googlevideo.com)
	echo "$r" | cut -c1-900
	check "DNS (running): answers with the DNS plan of the running configuration" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" @.running)" = true ] && [ -n "$(jget "$r" @.plan.a.match.action)" ]'
	check "DNS: what the router cannot see is said, not claimed" 'jget "$r" "@.checks[*].code" | grep -qx client_secure_dns_unknown'
	# 1.0: the "DNS used" check and the plan describe the same server; the JSON
	# of the router must carry it in both places (a green "unknown" in LuCI)
	check "DNS: the 'DNS used' check names its server (kind $(jget "$r" "@.checks[@.id='server'].server.kind"), plan $(jget "$r" @.plan.a.match.server.kind))" \
		'[ -n "$(jget "$r" "@.checks[@.id=\"server\"].server.kind")" ] && [ "$(jget "$r" "@.checks[@.id=\"server\"].server.kind")" = "$(jget "$r" @.plan.a.match.server.kind)" ]'
	check "DNS: the 'DNS used' check is ok only with a known server" '[ "$(jget "$r" "@.checks[@.id=\"server\"].code")" != dns_server ] || [ "$(jget "$r" "@.checks[@.id=\"server\"].kind")" != unknown ]'
	r=$(diag connection)
	echo "$r" | cut -c1-900
	check "connection (running): seven items, core running" '[ "$(jget "$r" "@.items[*].id" | tr "\n" " ")" = "core dns nftables tproxy vless routing internet " ] && jget "$r" "@.items[0].checks[*].code" | grep -qx running'
	check "connection: nftables and TPROXY items carry the forwarding checks" 'jget "$r" "@.items[2].checks[*].code" | grep -qx table_ok && jget "$r" "@.items[3].checks[*].code" | grep -qx policy_ok'
	check "connection: routing - the running configuration has the four rules" 'jget "$r" "@.items[5].checks[*].code" | grep -qx running_config_ok'

	echo "== a server with a hostile name as the main node (1.0)"
	# the name of a node comes from a subscription; as the main node it is
	# written into the shell files the start reads
	rm -f /tmp/ev10-pwned*
	NAME_BEFORE=$(uci -q get $CONFIG.$GOOD.remarks)
	uci set $CONFIG.$GOOD.remarks='x"; touch /tmp/ev10-pwned-q; echo "$(touch /tmp/ev10-pwned-s)`touch /tmp/ev10-pwned-b` *'
	uci set $CONFIG.@global[0].node="$GOOD"
	uci commit $CONFIG
	call start >/dev/null
	if status_wait running 60; then ok "service running with a server as the main node"; else bad "service not running with the hostile node name"; call status; fi
	check "the node name was not run by the start" '[ -z "$(ls /tmp/ev10-pwned* 2>/dev/null)" ]'
	r=$(diag forwarding)
	check "forwarding is complete with that name (TCP $(jget "$r" @.tcp), UDP $(jget "$r" @.udp))" '[ "$(jget "$r" @.tcp)" = ok ] && [ "$(jget "$r" @.udp)" = ok ] && [ "$(jget "$r" @.status)" != fail ]'
	uci set $CONFIG.$GOOD.remarks="$NAME_BEFORE"
	uci set $CONFIG.@global[0].node='main_router'
	uci commit $CONFIG
	call start >/dev/null; status_wait running 60 || bad "service not running after the restart"
	check "nothing was run by the stop and the restart either" '[ -z "$(ls /tmp/ev10-pwned* 2>/dev/null)" ]'

	echo "== concurrency with the running service"
	( diag connection >$RACE.1 ) &
	p1=$!
	( call test "$(req action add kind server nodes "$GOOD $BADN")" >/dev/null ) &
	( explain '{"input":"yandex.ru"}' >$RACE.2 ) &
	p2=$!
	wait "$p1" "$p2"
	check "diagnostics + Route Explain while Server Tests are queued: both answer" '[ "$(jget "$(cat $RACE.1)" @.ok)" = true ] && { [ "$(jget "$(cat $RACE.2)" @.route.match.rule_id)" = RUSSIA ] || [ "$(jget "$(cat $RACE.2)" @.error)" = busy ]; }'
	i=0; while [ "$(jget "$(call test '{"action":"state"}')" @.running)" = true ] && [ "$i" -lt 120 ]; do sleep 1; i=$((i + 1)); done
	check "the test queue finished (nothing stuck in 'Testing')" '[ "$(jget "$(call test "{\"action\":\"state\"}")" @.running)" != true ]'
	check "the service is still the same running instance" '[ "$(jget "$(call status)" @.running)" = true ]'
	( diag connection >$RACE.1 ) &
	p1=$!
	call stop >/dev/null
	wait "$p1"
	status_wait stopped 60 || bad "service did not stop"
	check "diagnostics during a stop: a complete answer" '[ "$(jget "$(cat $RACE.1)" @.ok)" = true ]'
	check "after the stop: no table, no leftover" '! nft list table inet $CONFIG >/dev/null 2>&1 && [ "$(leftovers)" = 0 ]'
	r=$(diag forwarding)
	check "forwarding after the stop: clean 'off'" '[ "$(jget "$r" @.status)" = off ]'
else
	skip "running service: Route Explain on the running configuration, forwarding / DNS / connection diagnostics, their races"
fi

echo "== deleting servers"
r=$(nodes delete "$GOOD")
check "a server that is used is not deleted, with where it is used" '[ "$(jget "$r" @.ok)" = false ] && [ "$(jget "$r" @.error)" = used ] && [ "$(servers)" = 2 ] && [ -n "$(jget "$r" "@.references[0].option")" ]'
r=$(nodes delete "$BADN")
check "an unused server is deleted" '[ "$(jget "$r" @.ok)" = true ] && [ "$(servers)" = 1 ] && [ "$(jget "$r" @.excluded)" != true ]'
r=$(nodes delete "nosuchnode")
check "unknown server" '[ "$(jget "$r" @.ok)" = false ] && [ "$(jget "$r" @.error)" = unknown ]'
r=$(nodes delete 'x; reboot')
check "an id with shell characters is refused" '[ "$(jget "$r" @.ok)" = false ]'
r=$(call import "$(req links "$BAD_LINK")"); BADN=$(jget "$r" '@.nodes[0].id')
uci set $CONFIG.evgrp=nodes; uci set $CONFIG.evgrp.protocol='_urltest'; uci set $CONFIG.evgrp.remarks='Fastest'; uci set $CONFIG.evgrp.type='sing-box'
uci add_list $CONFIG.evgrp.urltest_node="$GOOD"; uci add_list $CONFIG.evgrp.urltest_node="$BADN"
uci set $CONFIG.main_router.UDP='evgrp'; uci commit $CONFIG
before=$(cfg_sum)
r=$(nodes delete_all_plan)
echo "$r"
check "delete all - plan: counts and what else changes" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" @.counts.manual)" = 2 ] && [ "$(jget "$r" @.counts.groups)" = 1 ] && jget "$r" "@.changes[*].kind" | grep -qx default && jget "$r" "@.changes[*].kind" | grep -qx group_removed'
check "delete all - plan: nothing changed" '[ "$(cfg_sum)" = "$before" ]'
if [ -n "${SUB_URL:-}" ]; then
	uci set $CONFIG.s_slow=subscribe_list; uci set $CONFIG.s_slow.remark='s_slow'; uci set $CONFIG.s_slow.url="$SUB_URL/slow"; uci commit $CONFIG
	before=$(cfg_sum)
	call subscribe '{"action":"update","id":"s_slow"}' >/dev/null
	sleep 1
	r=$(nodes delete_all)
	check "delete all during a subscription update: refused as busy, nothing deleted" '[ "$(jget "$r" @.ok)" = false ] && [ "$(jget "$r" @.error)" = busy ] && [ "$(servers)" -ge 2 ]'
	r=$(nodes delete "$BADN")
	check "delete during a subscription update: refused as busy" '[ "$(jget "$r" @.error)" = busy ]'
	i=0; while [ "$(jget "$(call subscribe '{"action":"state"}')" @.busy)" = true ] && [ "$i" -lt 90 ]; do sleep 1; i=$((i + 1)); done
	i=0; while [ -f /var/lock/$CONFIG.lock ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
	check "the update itself finished and imported its servers" '[ "$(uci -q show $CONFIG | grep -c "\.group=.s_slow.$")" = 2 ]'
	/etc/init.d/easy_vless stop >/dev/null 2>&1
fi
r=$(nodes delete_all)
echo "$r" | cut -c1-500
check "delete all: done" '[ "$(jget "$r" @.ok)" = true ] && [ "$(servers)" = 0 ]'
check "delete all: the emptied URL Test group is gone" '[ -z "$(uci -q get $CONFIG.evgrp)" ]'
check "delete all: Default -> Direct, rule targets -> Default target, Direct rule untouched" '[ "$(uci -q get $CONFIG.main_router.default_node)" = _direct ] && [ "$(uci -q get $CONFIG.main_router.PROXY)" = _default ] && [ "$(uci -q get $CONFIG.main_router.UDP)" = _default ] && [ "$(uci -q get $CONFIG.main_router.RUSSIA)" = _direct ]'
check "delete all: rules and the Main Router are kept" '[ "$(uci -q get $CONFIG.PROXY)" = shunt_rules ] && [ "$(uci -q get $CONFIG.@global[0].node)" = main_router ]'
[ -n "${SUB_URL:-}" ] && check "delete all: the subscription itself is kept" '[ "$(uci -q get $CONFIG.s_slow)" = subscribe_list ]'
r=$(call check)
check "delete all: the remaining configuration is still valid (no broken target)" '[ "$(jget "$r" @.ok)" = true ]'
r=$(diag connection)
check "delete all: diagnostics see consistent targets and no server" 'jget "$r" "@.items[5].checks[*].code" | grep -qx references_ok && jget "$r" "@.items[4].checks[*].code" | grep -qx no_proxy_target'
r=$(nodes delete_all)
check "delete all without servers: nothing to do" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" @.service)" = none ]'
# a server as the main node: nothing is left to start
reset_config
r=$(call import "$(req links "$GOOD_LINK")"); GOOD=$(jget "$r" '@.nodes[0].id')
uci set $CONFIG.@global[0].node="$GOOD"; uci set $CONFIG.@global[0].enabled='1'; uci commit $CONFIG
/etc/init.d/easy_vless stop >/dev/null 2>&1
r=$(nodes delete_all)
check "delete all with a server as the main node: main node cleared, main switch off, service stopped" '[ "$(jget "$r" @.stop)" = true ] && [ "$(jget "$r" @.service)" = stop ] && [ -z "$(uci -q get $CONFIG.@global[0].node)" ] && [ "$(uci -q get $CONFIG.@global[0].enabled)" = 0 ]'
status_wait stopped 60 || bad "service not stopped after delete all"

echo "== Backup / Restore"
reset_config
r=$(call import "$(req links "$GOOD_LINK")"); GOOD=$(jget "$r" '@.nodes[0].id')
wizard_routing "$GOOD"
original=$(cfg_sum)
r=$(transfer backup)
BK=$(jget "$r" @.content)
check "backup: a file with a name and content" '[ "$(jget "$r" @.ok)" = true ] && [ -n "$BK" ] && jget "$r" @.filename | grep -q "^easy-vless-backup-.*\.json$"'
check "backup: format and checksum" '[ "$(jget "$BK" @.format)" = easy-vless-backup ] && [ "$(jget "$BK" @.sha256 | wc -c)" = 65 ]'
r=$(transfer restore_check "$BK")
check "restore check: accepted, with a summary" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" @.summary.servers)" = 1 ] && [ "$(jget "$r" @.summary.rules)" = 4 ]'
check "restore check changes nothing" '[ "$(cfg_sum)" = "$original" ]'
uci set $CONFIG.@global[0].loglevel='debug'; uci -q delete $CONFIG.PROXY; uci -q delete $CONFIG.main_router.PROXY; uci commit $CONFIG
changed=$(cfg_sum)
check "the configuration was changed after the backup" '[ "$changed" != "$original" ]'
bad_bk=$(echo "$BK" | sed 's/Wizard Test/Wizard Evil/')
r=$(transfer restore_apply "$bad_bk")
check "a modified backup is refused (damaged), the configuration is untouched" '[ "$(jget "$r" @.ok)" = false ] && [ "$(jget "$r" @.error.code)" = damaged ] && [ "$(cfg_sum)" = "$changed" ]'
r=$(transfer restore_apply 'not json at all')
check "a file that is not JSON is refused, the configuration is untouched" '[ "$(jget "$r" @.ok)" = false ] && [ "$(jget "$r" @.error.code)" = not_json ] && [ "$(cfg_sum)" = "$changed" ]'
EXN=$(jget "$(transfer export "" nodes)" @.content)
r=$(transfer restore_apply "$EXN")
check "an export file is not accepted as a backup" '[ "$(jget "$r" @.error.code)" = not_backup ] && [ "$(cfg_sum)" = "$changed" ]'
r=$(transfer restore_apply "$BK")
echo "$r" | cut -c1-300
check "restore: applied" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" @.rollback)" = true ]'
status_wait stopped 60 || true
check "restore: the configuration is the one of the backup" '[ "$(cfg_sum)" = "$original" ]'
check "restore: the configuration is valid" '[ "$(jget "$(call check)" @.ok)" = true ]'
r=$(transfer state)
check "after a restore: an undo is available" '[ "$(jget "$r" @.rollback)" = true ]'
r=$(transfer rollback)
status_wait stopped 60 || true
check "undo: the configuration from before the restore is back" '[ "$(jget "$r" @.ok)" = true ] && [ "$(cfg_sum)" = "$changed" ]'
r=$(transfer rollback)
check "undo twice: nothing to go back to" '[ "$(jget "$r" @.error.code)" = no_rollback ]'
check "no temporary files left" '[ "$(leftovers)" = 0 ]'

echo "== Import / Export"
r=$(transfer restore_apply "$BK"); status_wait stopped 60 || true
EXN=$(jget "$(transfer export "" nodes)" @.content)
EXR=$(jget "$(transfer export "" rules)" @.content)
check "export: servers and rules" '[ "$(jget "$EXN" @.kind)" = nodes ] && [ "$(jget "$EXR" @.kind)" = rules ] && [ "$(jget "$EXR" "@.items[0].target")" = _direct ]'
check "export: a rule on a server carries no target" '[ -z "$(jget "$EXR" "@.items[1].target")" ]'
r=$(transfer export "" settings)
check "export: unknown kind refused" '[ "$(jget "$r" @.ok)" = false ]'
r=$(transfer import_check "$EXN")
check "import check on the same router: everything already exists" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" @.count)" = 0 ] && [ "$(jget "$r" "@.skipped[0].reason")" = exists ]'
r=$(transfer import_apply "$EXN")
check "import with nothing new: refused, nothing changed" '[ "$(jget "$r" @.ok)" = false ] && [ "$(jget "$r" @.error.code)" = nothing ] && [ "$(cfg_sum)" = "$original" ]'
reset_config
empty=$(cfg_sum)
r=$(transfer import_apply "$BK")
check "a backup is not accepted as an import" '[ "$(jget "$r" @.error.code)" = not_export ] && [ "$(cfg_sum)" = "$empty" ]'
r=$(transfer import_apply "$EXN" rules)
check "servers where rules were asked for: refused" '[ "$(jget "$r" @.error.code)" = kind_mismatch ] && [ "$(cfg_sum)" = "$empty" ]'
evil=$(echo "$EXN" | sed 's/"protocol": *"vless"/"protocol":"trojan"/')
check "the test file really differs" '[ "$evil" != "$EXN" ]'
r=$(transfer import_apply "$evil")
check "an invalid entry is not imported, the configuration is untouched" '[ "$(jget "$r" @.ok)" = false ] && [ "$(servers)" = 0 ] && [ "$(cfg_sum)" = "$empty" ]'
r=$(transfer import_check "$EXN")
check "import check into an empty configuration: one server to add, nothing changed yet" '[ "$(jget "$r" @.count)" = 1 ] && [ "$(servers)" = 0 ]'
r=$(transfer import_apply "$EXN")
check "import: the server is added" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" @.added)" = 1 ] && [ "$(servers)" = 1 ]'
id=$(uci -q show $CONFIG | sed -n "s/^$CONFIG\.\([^.]*\)\.protocol='vless'$/\1/p" | head -n 1)
check "import: stored as an imported server, with its data" '[ "$(uci -q get $CONFIG.$id.add_mode)" = 1 ] && echo "$GOOD_LINK" | grep -qF "@$(uci -q get $CONFIG.$id.address):$(uci -q get $CONFIG.$id.port)?"'
r=$(transfer import_apply "$EXR")
check "import: the four rules are added, with their special target only" '[ "$(jget "$r" @.added)" = 4 ] && [ "$(uci -q show $CONFIG | grep -c "=shunt_rules$")" = 4 ]'
rid=$(uci -q show $CONFIG | sed -n "s/^$CONFIG\.\([^.]*\)\.remarks='RUSSIA'$/\1/p" | head -n 1)
check "import: RUSSIA -> Direct came with the rule, PROXY has no target" '[ "$(uci -q get $CONFIG.main_router.$rid)" = _direct ] && [ "$(uci -q show $CONFIG.main_router | grep -c "_direct")" -ge 1 ]'
r=$(transfer import_apply "$EXR")
check "import again: nothing is duplicated" '[ "$(jget "$r" @.error.code)" = nothing ] && [ "$(uci -q show $CONFIG | grep -c "=shunt_rules$")" = 4 ]'

echo "== update method"
r=$(call update '{"action":"state"}')
check "update state answers" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" @.busy)" = false ]'
r=$(call update "$(req action install tag 'v9.9.9; reboot')")
check "install with an invalid tag is refused" '[ "$(jget "$r" @.ok)" = false ] && [ "$(jget "$r" @.error)" = tag ]'
r=$(call update '{"action":"nosuch"}')
check "unknown update action" '[ "$(jget "$r" @.ok)" = false ]'

reset_config
rm -f $RACE.* /tmp/ev09-pwned
echo
echo "===== 0.9 backend tests: $PASS passed, $FAIL failed, $SKIP skipped (QEMU emulation limits) ====="
[ "$FAIL" -eq 0 ]
