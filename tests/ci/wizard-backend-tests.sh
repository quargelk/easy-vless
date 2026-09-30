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

echo "== Server Test queue (0.8.0): Test All, repeated click, stored results, cancel"
# rpcd "test": LuCI queues tests and polls "state"; one test at a time, a
# server that is already queued or running is not queued again, the last
# result of every server stays on the router (tmpfs).
tstate() { call test '{"action":"state"}'; }
tadd() { call test "{\"action\":\"add\",\"kind\":\"$1\",\"nodes\":\"$2\"}"; }
pending() { # queued + running tests in a state answer
	echo $(( $(jget "$1" '@.queue[*].node' | grep -c .) + $([ -n "$(jget "$1" '@.current.node')" ] && echo 1 || echo 0) ))
}
tresult() { # tresult <state> <node> <kind> <field>: of the stored result
	jget "$1" '@.results[*]' | grep "\"node\": *\"$2\"" | grep "\"kind\": *\"$3\"" | head -n 1 | {
		read -r line; [ -n "$line" ] && jsonfilter -s "$line" -e "@.result.$4" 2>/dev/null; }
}
twait() { # twait [seconds]: until the runner is idle; prints the last state
	i=0; tw=$(tstate)
	while [ "$(jget "$tw" @.running)" = true ] && [ "$i" -lt "${1:-120}" ]; do sleep 1; i=$((i + 1)); tw=$(tstate); done
	echo "$tw"
}
st=$(tstate)
check "test state answers (no test running)" '[ "$(jget "$st" @.ok)" = true ] && [ "$(jget "$st" @.running)" = false ]'
check "the Server Test above stored its result (sync urltest_node)" '[ -n "$(tresult "$st" "$BADN" server time)" ] && [ "$(tresult "$st" "$BADN" server ok)" = false ]'
r=$(tadd server "$GOOD $BADN nosuchnode")
echo "$r" | head -c 400; echo
check "Test All: queued, unknown server ignored" '[ "$(jget "$r" @.ok)" = true ] && [ "$(pending "$r")" = 2 ] && [ "$(jget "$r" @.total)" = 2 ]'
check "Test All: the runner is running (Testing state)" '[ "$(jget "$r" @.running)" = true ]'
r=$(tadd server "$GOOD $BADN")
check "repeated click: no duplicate test (still 2, total 2)" '[ "$(pending "$r")" -le 2 ] && [ "$(jget "$r" @.total)" = 2 ]'
i=0; while [ "$i" -lt 100 ]; do n=$(busybox pgrep -f 'url_test_' | grep -c .); [ "$n" -gt 1 ] && break; i=$((i + 1)); done
check "never more than one test instance at a time" '[ "$(busybox pgrep -f "sing-box run -c .*url_test_" | grep -c .)" -le 1 ]'
st=$(twait 120)
echo "$st" | head -c 600; echo
check "Test All finished: runner idle, queue empty, 2 of 2 done" '[ "$(jget "$st" @.running)" = false ] && [ "$(pending "$st")" = 0 ] && [ "$(jget "$st" @.done)" = 2 ]'
check "closed port: stored result failed, with a reason" '[ "$(tresult "$st" "$BADN" server ok)" = false ] && [ -n "$(tresult "$st" "$BADN" server error_kind)" ]'
check "results carry the tested address and port" '[ "$(tresult "$st" "$BADN" server port)" = 20444 ]'
if [ "$SOMARK" = 1 ]; then
	check "working server: stored result passed with a latency" '[ "$(tresult "$st" "$GOOD" server ok)" = true ] && [ "$(tresult "$st" "$GOOD" server delay)" -gt 0 ]'
else
	check "working server: a stored result exists (SO_MARK not emulated here)" '[ -n "$(tresult "$st" "$GOOD" server time)" ]'
fi
busybox pgrep -f "url_test_" >/dev/null && bad "test instances left running after Test All: $(busybox pgrep -af url_test_)" || ok "no test instance left after Test All"
r=$(tadd url "$GOOD")
st=$(twait 60)
check "URL Test through the queue stored a url result for https://x.com" '[ "$(tresult "$st" "$GOOD" url url)" = "https://x.com" ]'
[ "$SOMARK" = 1 ] && check "URL Test through the queue passed" '[ "$(tresult "$st" "$GOOD" url ok)" = true ]'
r=$(tadd server "$BADN $GOOD")
r=$(call test '{"action":"cancel"}')
check "cancel: the queued tests are dropped" '[ "$(jget "$r" "@.queue[*].node" | grep -c .)" = 0 ]'
st=$(twait 60)
check "cancel: the running test finished, nothing left" '[ "$(jget "$st" @.running)" = false ] && [ "$(pending "$st")" = 0 ] && [ "$(jget "$st" @.done)" -le 1 ]'
# a killed runner never leaves a hanging "Testing" state
r=$(tadd server "$BADN $GOOD")
kill -9 "$(cat /var/run/easy_vless_test/runner.pid)" 2>/dev/null
st=$(tstate)
check "killed runner: no test shown as running or queued" '[ "$(jget "$st" @.running)" = false ] && [ "$(pending "$st")" = 0 ]'
i=0; while busybox pgrep -f "url_test_" >/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
check "killed runner: its last test instance ends by itself" '! busybox pgrep -f "url_test_" >/dev/null'
r=$(call test '{"action":"clear","nodes":"'"$BADN"'"}')
check "clear: stored results of an edited server are dropped" '[ -z "$(tresult "$r" "$BADN" server time)" ]'
r=$(call test '{"action":"add","kind":"nonsense","nodes":"'"$GOOD"'"}')
check "unknown test kind refused" '[ "$(jget "$r" @.ok)" = false ]'
# Test All while the service is stopped: the stop does not kill the runner
# (0.7.2 sweep of "easy_vless/" processes) and goes first (op_lock waiters)
r=$(tadd server "$GOOD $BADN")
r=$(tadd url "$GOOD $BADN")
i=0; until [ -n "$(jget "$(tstate)" @.current.node)" ] || [ "$i" -ge 20 ]; do sleep 1; i=$((i + 1)); done
/usr/share/easy_vless/app.sh stop >/dev/null 2>&1
st=$(tstate)
check "stop during Test All: finished before the queue (a service operation goes first)" '[ "$(jget "$st" @.running)" = true ] && [ "$(pending "$st")" -ge 1 ]'
st=$(twait 180)
check "stop during Test All: the runner survived and finished all 4 tests" '[ "$(jget "$st" @.running)" = false ] && [ "$(jget "$st" @.done)" = 4 ]'
check "stop during Test All: every test has a result" '[ -n "$(tresult "$st" "$GOOD" url time)" ] && [ -n "$(tresult "$st" "$BADN" url time)" ]'
[ "$SOMARK" = 1 ] && check "stop during Test All: the working server still passed" '[ "$(tresult "$st" "$GOOD" server ok)" = true ]'
# configuration check while tests run: waits for the lock, not killed
r=$(tadd server "$GOOD $BADN")
out=$(/usr/share/easy_vless/app.sh check "$GOOD" 2>&1); rc=$?
check "check during Test All passes (no Killed / decode config / Broken pipe)" '[ "$rc" = 0 ] && ! echo "$out" | grep -qE "Killed|decode config|Broken pipe"'
twait 120 >/dev/null

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

echo "== concurrent operations: check / Server Test while the service is stopped or reloaded"
# 0.7.1 bug: LuCI commits the configuration (uci commit through rpcd) right
# before Check config / Save & Start; ucitrack then reloads the service in
# the background (procd -> /etc/init.d/easy_vless reload = app.sh stop +
# start), and app.sh stop kills leftover "easy_vless/" processes - also the
# config generator of the check running at that moment: "Killed",
# "decode config ...: EOF", "sh: write error: Broken pipe". The generator is
# frozen (SIGSTOP) while the competing operation runs, so the overlap does
# not depend on timing; it continues after a few seconds.
RACE=/tmp/ev-race
LOGF=/tmp/log/$CONFIG.log
# the service log directory (normally created by a start): app.sh stop writes its
# "complete" line there, which is how the tests see that a competing stop ran
mkdir -p /tmp/log
stops() { # number of "stop complete" log lines: always exactly one integer (0 without a match or a log)
	_sn=$(grep -c "Clearing and closing related programs and cache complete" "$LOGF" 2>/dev/null)
	case "$_sn" in ""|*[!0-9]*) _sn=0 ;; esac
	echo "$_sn"
}
race_check() { # race_check <label> <competing command> [seconds]: the command runs while the generator is frozen
	try=0; gen=""
	while [ -z "$gen" ] && [ "$try" -lt 3 ]; do
		try=$((try + 1))
		rm -f $RACE.out $RACE.rc
		( /usr/share/easy_vless/app.sh check >$RACE.out 2>&1; echo $? >$RACE.rc ) &
		i=0
		while [ -z "$gen" ] && [ ! -s $RACE.rc ] && [ "$i" -lt 5000 ]; do
			gen=$(busybox pgrep -f 'util_sing-box\.lua gen_config' | head -n1); i=$((i + 1))
		done
		[ -z "$gen" ] && { i=0; while [ ! -s $RACE.rc ] && [ "$i" -lt 120 ]; do sleep 1; i=$((i + 1)); done; }
	done
	check "$1: the config generator of the check was caught running" '[ -n "$gen" ]'
	[ -n "$gen" ] || return
	kill -STOP "$gen"
	sh -c "$2" >/dev/null 2>&1 &
	comp=$!
	sleep "${3:-3}"
	kill -CONT "$gen" 2>/dev/null
	i=0; while [ ! -s $RACE.rc ] && [ "$i" -lt 120 ]; do sleep 1; i=$((i + 1)); done
	wait "$comp" 2>/dev/null
	out=$(cat $RACE.out 2>/dev/null)
	echo "$out" | tail -n 4
	check "$1: the check passes" '[ "$(cat $RACE.rc 2>/dev/null)" = 0 ] && echo "$out" | grep -q "^OK: sing-box"'
	check "$1: generator not killed (no Killed / decode config / Broken pipe)" '! echo "$out" | grep -qE "Killed|decode config|Broken pipe"'
}
n0=$(stops)
race_check "check during app.sh stop" "/usr/share/easy_vless/app.sh stop"
check "the competing stop did run" '[ "$(stops)" -gt "$n0" ]'

# The same through the real trigger: rpcd uci commit (as LuCI's Save) ->
# config.change -> procd/ucitrack -> /etc/init.d/easy_vless reload.
if ubus -t 2 list service >/dev/null 2>&1 && [ -x /etc/init.d/ucitrack ]; then
	/etc/init.d/easy_vless enabled || /etc/init.d/easy_vless enable
	/etc/init.d/ucitrack restart >/dev/null 2>&1
	sleep 1
	check "ucitrack registered the easy_vless reload trigger" 'ubus call service list "{\"name\":\"ucitrack\",\"verbose\":true}" | grep -q "easy_vless"'
	n0=$(stops)
	race_check "check during the reload after a LuCI commit" "ubus call uci commit '{\"config\":\"$CONFIG\"}'" 8
	i=0; while [ "$(stops)" -le "$n0" ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
	check "the commit reloaded the service (ucitrack), after the check" '[ "$(stops)" -gt "$n0" ]'
	status_wait stopped 60 || true
	# later tests (and the LuCI end-to-end test) commit through rpcd: no
	# background reloads there
	/etc/init.d/ucitrack stop >/dev/null 2>&1
elif [ "$NFT" = 0 ]; then
	SKIP=$((SKIP + 1))
	echo "SKIP: check during the reload after a LuCI commit - procd (ucitrack triggers) does not run under QEMU user emulation ($(uname -m)); tested on x86-64 (the app.sh stop case above runs here)"
else
	bad "procd service object or /etc/init.d/ucitrack missing: the commit -> reload path cannot be tested"
fi

# Server Test while the service is stopped: its temporary instance was
# killed by the stop in 0.7.1.
if [ "$SOMARK" = 1 ]; then
	( call urltest_node "{\"node\":\"$GOOD\"}" >$RACE.ut ) &
	utp=$!
	i=0; until busybox pgrep -f "url_test_${GOOD}" >/dev/null || [ "$i" -ge 5000 ]; do i=$((i + 1)); done
	/usr/share/easy_vless/app.sh stop >/dev/null 2>&1
	wait "$utp"
	cat $RACE.ut
	check "Server Test during app.sh stop still passes" '[ "$(jget "$(cat $RACE.ut)" @.ok)" = true ]'
fi
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

echo "== subscriptions (0.8.0): formats, failures keep the nodes, request strategy, repeated update"
# SUB_URL: tests/ci/sub-server.py (its own container); it records every
# request (User-Agent, X-HWID, X-Device-*), GET $SUB_URL/_log
if [ -n "${SUB_URL:-}" ]; then
	sub() { call subscribe "{\"action\":\"$1\",\"id\":\"${2:-}\"}"; }
	subset() { # subset <id> <path> [user_agent] [hwid]
		uci -q delete $CONFIG.$1
		uci set $CONFIG.$1=subscribe_list
		uci set $CONFIG.$1.remark="$1"
		uci set $CONFIG.$1.url="$SUB_URL/$2"
		[ -n "${3:-}" ] && uci set $CONFIG.$1.user_agent="$3"
		[ -n "${4:-}" ] && uci set $CONFIG.$1.hwid="$4"
		uci commit $CONFIG
	}
	subwait() { # subwait: until no update runs; prints the last state
		i=0; sw=$(sub state)
		while [ "$(jget "$sw" @.busy)" = true ] && [ "$i" -lt 90 ]; do sleep 1; i=$((i + 1)); sw=$(sub state); done
		echo "$sw"
	}
	subrun() { # subrun <id>: update it, wait; prints its result record
		r=$(sub update "$1")
		[ "$(jget "$r" @.code)" = 0 ] || { echo "{\"status\":\"refused\",\"output\":\"$(jget "$r" @.output)\"}"; return; }
		subwait >/dev/null
		# subscribe.lua restarts the service in the background after an update
		i=0; while [ -f /var/lock/$CONFIG.lock ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
		jget "$(sub state)" "@.results.$1"
	}
	rec() { jsonfilter -s "$1" -e "@.$2" 2>/dev/null; }
	group() { uci -q show $CONFIG | grep -c "\.group='$1'$"; }
	slog() { curl -s --max-time 10 "$SUB_URL/_log"; }
	sreset() { curl -s --max-time 10 -o /dev/null "$SUB_URL/_reset"; }
	nreq() { slog | jsonfilter -e '@[*].path' | grep -c .; }
	req() { slog | jsonfilter -e "@[$1].$2"; }   # req <index> <field>

	for fmt in "plain:URL list" "b64:base64 URL list" "clash:Clash YAML" "singbox:sing-box JSON"; do
		p=${fmt%%:*}; f=${fmt#*:}
		subset "s_$p" "$p"
		r=$(subrun "s_$p")
		echo "$p: $r"
		check "subscription $f: 2 VLESS servers received, the unsupported one skipped" '[ "$(rec "$r" status)" = ok ] && [ "$(rec "$r" found)" = 2 ] && [ "$(rec "$r" format)" = "$f" ]'
		check "subscription $f: 2 servers of this subscription in the node list" '[ "$(group "s_$p")" = 2 ] && [ "$(rec "$r" after)" = 2 ]'
	done
	# a Server Test result survives the update (the servers get new ids)
	old=$(uci -q show $CONFIG | sed -n "s/^$CONFIG\.\([^.]*\)\.port='20444'$/\1/p" | while read -r n; do [ "$(uci -q get $CONFIG.$n.group)" = s_plain ] && echo "$n"; done | head -n 1)
	call test "{\"action\":\"add\",\"kind\":\"server\",\"nodes\":\"$old\"}" >/dev/null
	twait 60 >/dev/null
	r=$(subrun s_plain)
	new=$(uci -q show $CONFIG | sed -n "s/^$CONFIG\.\([^.]*\)\.port='20444'$/\1/p" | while read -r n; do [ "$(uci -q get $CONFIG.$n.group)" = s_plain ] && echo "$n"; done | head -n 1)
	st=$(tstate)
	check "subscription update: the tested server got a new id and keeps its last Server Test result" '[ -n "$old" ] && [ -n "$new" ] && [ "$new" != "$old" ] && [ -n "$(tresult "$st" "$new" server time)" ] && [ -z "$(tresult "$st" "$old" server time)" ]'
	check "repeated update: servers replaced, not duplicated (before 2, now 2)" '[ "$(rec "$r" status)" = ok ] && [ "$(rec "$r" before)" = 2 ] && [ "$(rec "$r" after)" = 2 ] && [ "$(group s_plain)" = 2 ]'
	check "a successful update records its time in UCI" '[ -n "$(uci -q get $CONFIG.s_plain.update_time)" ]'
	for bad in "html:no_nodes" "empty:empty" "unsupported:no_nodes" "status/500:download" "status/404:download"; do
		p=${bad%%:*}; want=${bad#*:}
		uci set $CONFIG.s_plain.url="$SUB_URL/$p"; uci commit $CONFIG
		r=$(subrun s_plain)
		echo "$p: $r"
		check "invalid answer ($p): status $want, the 2 existing servers are kept" '[ "$(rec "$r" status)" = "$want" ] && [ "$(group s_plain)" = 2 ] && [ "$(rec "$r" before)" = 2 ] && [ "$(rec "$r" after)" = 2 ]'
	done
	check "HTTP status of a failed download is recorded" '[ "$(rec "$r" http_code)" = 404 ]'

	echo "-- request strategy (User-Agent / HWID)"
	subset s_ua happ-403
	sreset; r=$(subrun s_ua)
	check "default request (curl) to a HAPP-only provider: refused (403), one request, curl User-Agent" '[ "$(rec "$r" status)" = download ] && [ "$(nreq)" = 1 ] && req 0 ua | grep -q "^curl/"'
	subset s_ua happ-403 HAPP
	sreset; r=$(subrun s_ua)
	check "User-Agent HAPP: accepted, one request with User-Agent HAPP" '[ "$(rec "$r" status)" = ok ] && [ "$(nreq)" = 1 ] && [ "$(req 0 ua)" = HAPP ] && [ "$(rec "$r" request)" = HAPP ]'
	subset s_ua happ-403 auto
	sreset; r=$(subrun s_ua)
	check "Auto, HTTP 403 for curl: exactly one more request as HAPP, accepted" '[ "$(rec "$r" status)" = ok ] && [ "$(nreq)" = 2 ] && req 0 ua | grep -q "^curl/" && [ "$(req 1 ua)" = HAPP ] && [ "$(rec "$r" fallback)" = true ]'
	subset s_ua happ-200 auto
	sreset; r=$(subrun s_ua)
	check "Auto, placeholder without servers for curl: one more request as HAPP, accepted" '[ "$(rec "$r" status)" = ok ] && [ "$(nreq)" = 2 ] && [ "$(req 1 ua)" = HAPP ]'
	subset s_ua plain auto
	sreset; r=$(subrun s_ua)
	check "Auto, normal provider: one request only (no HAPP request)" '[ "$(rec "$r" status)" = ok ] && [ "$(nreq)" = 1 ] && [ "$(rec "$r" fallback)" != true ]'
	subset s_ua status/500 auto
	sreset; r=$(subrun s_ua)
	# curl's own --retry 3 repeats a 5xx answer; Auto adds no HAPP request
	check "Auto, server error 500: no HAPP request (only curl's own retries)" '[ "$(rec "$r" status)" = download ] && [ "$(rec "$r" fallback)" != true ] && ! slog | jsonfilter -e "@[*].ua" | grep -qx HAPP'
	subset s_ua html auto
	sreset; r=$(subrun s_ua)
	check "Auto, no servers for both requests: two requests, nothing more; existing nodes kept" '[ "$(rec "$r" status)" = no_nodes ] && [ "$(nreq)" = 2 ] && [ "$(group s_ua)" -ge 2 ]'
	subset s_ua plain "EasyTest/1.0 (router)"
	sreset; r=$(subrun s_ua)
	check "custom User-Agent sent as is" '[ "$(req 0 ua)" = "EasyTest/1.0 (router)" ] && [ "$(rec "$r" request)" = custom ]'
	subset s_hw hwid
	sreset; r=$(subrun s_hw)
	check "HWID off: no X-HWID sent, the HWID-only provider refuses (404)" '[ "$(rec "$r" status)" = download ] && [ -z "$(req 0 hwid)" ]'
	subset s_hw hwid "" 1
	sreset; r=$(subrun s_hw)
	check "HWID on: accepted, X-HWID = /etc/easy_vless/hwid, X-Device-OS OpenWrt" '[ "$(rec "$r" status)" = ok ] && [ "$(req 0 hwid)" = "$(cat /etc/easy_vless/hwid)" ] && [ "$(req 0 os)" = OpenWrt ]'
	. /etc/openwrt_release
	check "HWID on: X-Ver-OS = the OpenWrt release" '[ "$(req 0 ver)" = "$DISTRIB_RELEASE" ]'
	[ -s /tmp/sysinfo/model ] && check "HWID on: X-Device-Model = the router model" '[ "$(req 0 model)" = "$(cat /tmp/sysinfo/model)" ]'
	h1=$(cat /etc/easy_vless/hwid)
	subset s_hw hwid auto 1
	sreset; r=$(subrun s_hw)
	check "HWID + Auto: one request with X-HWID, the same stable HWID" '[ "$(rec "$r" status)" = ok ] && [ "$(nreq)" = 1 ] && [ "$(req 0 hwid)" = "$h1" ] && [ "$(cat /etc/easy_vless/hwid)" = "$h1" ]'

	echo "-- repeated update, update vs service operations"
	# a node of a subscription as the main node: the check has a configuration
	nid=$(uci -q show $CONFIG | sed -n "s/^$CONFIG\.\([^.]*\)\.group='s_plain'$/\1/p" | head -n 1)
	uci set $CONFIG.@global[0].node="$nid"; uci commit $CONFIG
	subset s_slow slow
	r1=$(sub update s_slow)
	sleep 1
	r2=$(sub update s_slow)
	check "update started" '[ "$(jget "$r1" @.code)" = 0 ]'
	check "second update while one runs: refused" '[ "$(jget "$r2" @.code)" = 1 ]'
	check "state: busy while the update runs" '[ "$(jget "$(sub state)" @.busy)" = true ]'
	out=$(/usr/share/easy_vless/app.sh check 2>&1); rc=$?
	echo "$out" | tail -n 3
	check "check during a subscription update passes (no Killed / decode config / Broken pipe)" '[ -n "$nid" ] && [ "$rc" = 0 ] && ! echo "$out" | grep -qE "Killed|decode config|Broken pipe"'
	st=$(subwait)
	check "update finished: not busy, 2 servers" '[ "$(jget "$st" @.busy)" = false ] && [ "$(group s_slow)" = 2 ]'
	r=$(sub update nosuchsub)
	check "unknown subscription refused" '[ "$(jget "$r" @.code)" = 1 ]'
	uci -q delete $CONFIG.s_slow; uci commit $CONFIG
	st=$(sub state)
	check "a deleted subscription has no result any more" '[ -z "$(jget "$st" @.results.s_slow)" ]'
	i=0; while [ -f /var/lock/$CONFIG.lock ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
	reset_config
else
	bad "SUB_URL (subscription test server) is not set"
fi

echo
echo "===== wizard backend tests: $PASS passed, $FAIL failed, $SKIP skipped (QEMU emulation limits) ====="
[ "$FAIL" -eq 0 ]
