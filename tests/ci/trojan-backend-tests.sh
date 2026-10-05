#!/bin/sh
# Easy VLESS 1.1 - Trojan: backend tests through ubus (rpcd object
# luci.easy_vless), inside the OpenWrt rootfs container prepared by
# tests/ci/wizard-setup.sh (CI, tests/ci/wizard-tests.sh).
#
#   TROJAN_LINK         trojan:// link of a real Trojan server (sing-box with
#                       a Trojan inbound and a self-signed certificate in
#                       another container), with allowInsecure=1
#   TROJAN_STRICT_LINK  the same server without allowInsecure: the
#                       certificate is verified, so the test must fail
#   TROJAN_PW           the password of that server
#   GOOD_LINK           vless:// link of the VLESS test server
#   SUB_URL             tests/ci/sub-server.py (mixed VLESS + Trojan lists)
#
# Covered: import of trojan:// links (valid, invalid, hostile), the generated
# configuration and "sing-box check" of it, Server Test and URL Test through
# the real Trojan server, certificate verification, Trojan as the server of
# the routing (Route Explain, diagnostics, service start), mixed VLESS +
# Trojan subscriptions in every format, Backup / Restore, Export / Import.

. /usr/share/libubox/jshn.sh

CONFIG=easy_vless
PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $* - not emulated by QEMU user emulation ($(uname -m)); tested on x86-64"; }
check() { if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }
call() { ubus -t 120 call luci.easy_vless "$1" "${2:-{\}}" 2>&1; }
jget() { jsonfilter -s "$1" -e "$2" 2>/dev/null; }
req() {
	json_init
	while [ $# -ge 2 ]; do json_add_string "$1" "$2"; shift 2; done
	json_dump
}
get() { uci -q get $CONFIG.$1.$2; }
diag() { call diag "$(req action "$1" arg "${2:-}")"; }
transfer() { call transfer "$(req action "$1" data "${2:-}" kind "${3:-}")"; }
count() { uci -q show $CONFIG | grep -c "\.protocol='$1'$"; }
by_name() { uci -q show $CONFIG | sed -n "s/^$CONFIG\.\([^.]*\)\.remarks='$1'$/\1/p" | head -n 1; }
tstate() { call test '{"action":"state"}'; }
tresult() {
	jget "$1" '@.results[*]' | grep "\"node\": *\"$2\"" | grep "\"kind\": *\"$3\"" | head -n 1 | {
		read -r line; [ -n "$line" ] && jsonfilter -s "$line" -e "@.result.$4" 2>/dev/null; }
}
twait() {
	i=0; tw=$(tstate)
	while [ "$(jget "$tw" @.running)" = true ] && [ "$i" -lt "${1:-120}" ]; do sleep 1; i=$((i + 1)); tw=$(tstate); done
	echo "$tw"
}
status_wait() {
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
routing() { # the routing the First Run Wizard writes, PROXY / Default on $1, UDP on $2
	uci -q batch <<-EOF
		set $CONFIG.RUSSIA=shunt_rules
		set $CONFIG.RUSSIA.remarks='RUSSIA'
		set $CONFIG.RUSSIA.network='tcp,udp'
		add_list $CONFIG.RUSSIA.domain_resource='russia'
		set $CONFIG.PROXY=shunt_rules
		set $CONFIG.PROXY.remarks='PROXY'
		set $CONFIG.PROXY.network='tcp,udp'
		add_list $CONFIG.PROXY.domain_resource='proxy'
		set $CONFIG.UDP=shunt_rules
		set $CONFIG.UDP.remarks='UDP'
		set $CONFIG.UDP.network='udp'
		set $CONFIG.main_router.RUSSIA='_direct'
		set $CONFIG.main_router.PROXY='$1'
		set $CONFIG.main_router.UDP='$2'
		set $CONFIG.main_router.default_node='$1'
		set $CONFIG.@global[0].node='main_router'
		commit $CONFIG
	EOF
}
CHECK_CONFIG=/tmp/etc/${CONFIG}_check/config.json

TROJAN_PASSWORD=${TROJAN_PW:-}
[ -n "${TROJAN_LINK:-}" ] && [ -n "${TROJAN_STRICT_LINK:-}" ] && [ -n "$TROJAN_PASSWORD" ] && [ -n "${GOOD_LINK:-}" ] \
	|| { echo "TROJAN_LINK, TROJAN_STRICT_LINK, TROJAN_PW and GOOD_LINK are required"; exit 2; }
ubus -t 5 list luci.easy_vless >/dev/null 2>&1 || { echo "ubus object luci.easy_vless missing"; exit 2; }
NFT=0; [ -s /tmp/ev-nft-ok ] && NFT=1
rm -f /tmp/ev11-pwned*

echo "== import of trojan:// links"
reset_config
for l in "trojan://@192.0.2.1:443#no-password" "trojan://secret@192.0.2.1:99999#port" "trojan://secret@192.0.2.1:44x3#port" \
	"trojan://secret@192.0.2.1:443?type=xhttp&path=%2Fx#xhttp" "trojan://secret@192.0.2.1:443?type=kcp#kcp" "trojan://192.0.2.1:443#no-userinfo" \
	"trojan://secret@bad%20host%3Breboot:443#host"; do
	r=$(call import "$(req links "$l")")
	check "import adds no server for an invalid Trojan link ($l)" '[ "$(jget "$r" @.added)" = 0 ]'
done
check "invalid links: no servers" '[ "$(count trojan)" = 0 ] && [ "$(count vless)" = 0 ]'

r=$(call import "$(req links "$TROJAN_LINK")")
echo "$r" | cut -c1-500
TR=$(jget "$r" '@.nodes[0].id')
check "import of a trojan:// link adds one server" '[ "$(jget "$r" @.added)" = 1 ] && [ -n "$TR" ] && [ "$(jget "$r" "@.nodes[0].protocol")" = trojan ]'
check "the server is a Trojan node of sing-box in UCI" '[ "$(get "$TR" protocol)" = trojan ] && [ "$(get "$TR" type)" = sing-box ] && [ "$(get "$TR" add_mode)" = 1 ]'
check "password, address and port of the link" '[ "$(get "$TR" password)" = "$TROJAN_PASSWORD" ] && echo "$TROJAN_LINK" | grep -qF "@$(get "$TR" address):$(get "$TR" port)?"'
check "TLS with the SNI of the link, insecure only because the link says so" '[ "$(get "$TR" tls)" = 1 ] && [ "$(get "$TR" tls_serverName)" = trojan.test ] && [ "$(get "$TR" tls_allowInsecure)" = 1 ]'
check "no VLESS options on the Trojan node" '[ -z "$(get "$TR" uuid)" ] && [ -z "$(get "$TR" flow)" ]'
r=$(call import "$(req links "$TROJAN_STRICT_LINK")")
STRICT=$(jget "$r" '@.nodes[0].id')
check "a link without allowInsecure: the certificate will be verified" '[ -n "$STRICT" ] && [ "$(get "$STRICT" tls)" = 1 ] && [ "$(get "$STRICT" tls_allowInsecure)" = 0 ] && [ "$(get "$STRICT" tls_serverName)" = strict.trojan.test ]'
st=$(call wizard_state)
check "wizard state counts Trojan servers" '[ "$(jget "$st" @.servers)" = 2 ]'

# what a link carries is data: name, password and SNI with shell characters
EVIL_PW='$(touch /tmp/ev11-pwned-pw)`touch /tmp/ev11-pwned-bq`'"'"';"'
EVIL='trojan://%24%28touch%20%2Ftmp%2Fev11-pwned-pw%29%60touch%20%2Ftmp%2Fev11-pwned-bq%60%27%3B%22@192.0.2.9:443?sni=x.example.com&allowInsecure=0#Evil%20%24%28touch%20%2Ftmp%2Fev11-pwned-name%29%0A%3Cb%3E'
r=$(call import "$(req links "$EVIL")")
EV=$(jget "$r" '@.nodes[0].id')
check "a link with shell characters in password and name is imported as data" '[ -n "$EV" ] && [ "$(get "$EV" password)" = "$EVIL_PW" ]'
check "the name has no line break and no tags" '[ "$(get "$EV" remarks | wc -l)" = 1 ] && ! get "$EV" remarks | grep -q "[<>]"'
r=$(call import "$(req links 'trojan://secret@192.0.2.9:443?sni=x.example.com%3Btouch%20%2Ftmp%2Fev11-pwned-sni#Evil SNI')")
EVS=$(jget "$r" '@.nodes[0].id')

echo "== generated configuration, sing-box check"
r=$(call check "$(req node "$TR")")
check "check of the Trojan server: valid configuration" '[ "$(jget "$r" @.ok)" = true ]'
[ "$(jget "$r" @.ok)" = true ] || echo "$r"
for id in "$EV" "$EVS" "$STRICT"; do
	[ -n "$id" ] || continue
	r=$(call check "$(req node "$id")")
	check "check of $(get "$id" remarks | cut -c1-20): sing-box accepts or refuses it, nothing is run" '[ -n "$(jget "$r" @.ok)" ]'
done
check "nothing from a link was run as a command" '[ -z "$(ls /tmp/ev11-pwned* 2>/dev/null)" ]'
routing "$TR" "$TR"
r=$(call check)
check "Trojan as Default and rule target: valid configuration" '[ "$(jget "$r" @.ok)" = true ]'
[ "$(jget "$r" @.ok)" = true ] || echo "$r"
OB=$(jsonfilter -i "$CHECK_CONFIG" -e '@.outbounds[@.type="trojan"]' 2>/dev/null | head -n 1)
echo "generated outbound: $(echo "$OB" | sed "s/\"password\": *\"[^\"]*\"/\"password\":\"***\"/" | cut -c1-400)"
check "generated outbound: type trojan with server, port and password" '[ -n "$OB" ] && [ "$(jget "$OB" @.server)" = "$(get "$TR" address)" ] && [ "$(jget "$OB" @.server_port)" = "$(get "$TR" port)" ] && [ "$(jget "$OB" @.password)" = "$TROJAN_PASSWORD" ]'
check "generated outbound: TLS with the SNI" '[ "$(jget "$OB" @.tls.enabled)" = true ] && [ "$(jget "$OB" @.tls.server_name)" = trojan.test ] && [ "$(jget "$OB" @.tls.insecure)" = true ]'
check "generated outbound: no VLESS fields" '[ -z "$(jget "$OB" @.uuid)" ] && [ -z "$(jget "$OB" @.flow)" ] && [ -z "$(jget "$OB" @.packet_encoding)" ]'
if sing-box check -c "$CHECK_CONFIG" >/tmp/ev11-check.log 2>&1; then ok "sing-box check accepts the generated configuration"; else bad "sing-box check: $(cat /tmp/ev11-check.log)"; fi
# WebSocket + gRPC + HTTPUpgrade variants of the same node: still valid for sing-box
for t in ws grpc httpupgrade; do
	uci set $CONFIG.$TR.transport="$t"
	uci set $CONFIG.$TR.ws_path='/tr'; uci set $CONFIG.$TR.ws_host='cdn.example.com'
	uci set $CONFIG.$TR.grpc_serviceName='svc'
	uci set $CONFIG.$TR.httpupgrade_path='/up'; uci set $CONFIG.$TR.httpupgrade_host='cdn.example.com'
	uci commit $CONFIG
	r=$(call check)
	check "transport $t: sing-box accepts the Trojan outbound" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jsonfilter -i "$CHECK_CONFIG" -e "@.outbounds[@.type=\"trojan\"].transport.type" | head -n 1)" = "$t" ]'
	[ "$(jget "$r" @.ok)" = true ] || echo "$r"
done
for o in ws_path ws_host grpc_serviceName httpupgrade_path httpupgrade_host; do uci -q delete $CONFIG.$TR.$o; done
uci set $CONFIG.$TR.transport='tcp'; uci commit $CONFIG

echo "== Route Explain and diagnostics name the Trojan server"
r=$(diag explain '{"input":"www.googlevideo.com"}')
check "explain: the target is the Trojan server" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" @.route.match.target.kind)" = server ] && [ "$(jget "$r" @.route.match.target.id)" = "$TR" ] && [ "$(jget "$r" @.route.match.target.type)" = trojan ]'
r=$(diag explain '{"input":"yandex.ru"}')
check "explain: RUSSIA stays Direct" '[ "$(jget "$r" @.route.match.target.kind)" = direct ]'
r=$(diag connection)
check "connection diagnostics: the selected server is named with its protocol" 'jget "$r" "@.items[4].checks[*].code" | grep -qx node_server && jget "$r" "@.items[4].checks[*].protocol" | grep -qx trojan'
check "connection diagnostics: targets are consistent" 'jget "$r" "@.items[5].checks[*].code" | grep -qx references_ok'

echo "== Server Test / URL Test through the real Trojan server"
r=$(call urltest_node "$(req node "$TR")")
echo "$r"
if [ "$NFT" = 1 ]; then
	check "Server Test through the Trojan server passes" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" @.delay)" -gt 0 ]'
	r=$(call urltest_node "$(req node "$STRICT")")
	echo "$r"
	check "the same server with certificate verification: the self-signed certificate is refused" '[ "$(jget "$r" @.ok)" = false ]'
	uci set "$CONFIG.$TR.password=not-the-$TROJAN_PASSWORD"; uci commit $CONFIG
	r=$(call urltest_node "$(req node "$TR")")
	check "a wrong password does not pass the Server Test" '[ "$(jget "$r" @.ok)" = false ]'
	uci set "$CONFIG.$TR.password=$TROJAN_PASSWORD"; uci commit $CONFIG
	call test "$(req action add kind server nodes "$TR $STRICT")" >/dev/null
	st=$(twait 120)
	check "Test All: the Trojan server passed, the strict one failed with a reason" '[ "$(tresult "$st" "$TR" server ok)" = true ] && [ "$(tresult "$st" "$STRICT" server ok)" = false ] && [ -n "$(tresult "$st" "$STRICT" server error_kind)" ]'
	call test "$(req action add kind url nodes "$TR")" >/dev/null
	st=$(twait 120)
	check "URL Test through the Trojan server passed" '[ "$(tresult "$st" "$TR" url ok)" = true ]'
else
	check "Server Test of a Trojan server answers" '[ -n "$(jget "$r" @.ok)" ]'
	skip "Server Test / URL Test success through the Trojan server (SO_MARK)"
fi
busybox pgrep -f "url_test_" >/dev/null && bad "test instances left running: $(busybox pgrep -af url_test_)" || ok "no test instance left"

echo "== the service runs with the Trojan server"
if [ "$NFT" = 1 ]; then
	r=$(call start)
	check "start accepted" '[ "$(jget "$r" @.ok)" = true ]'
	if status_wait running 60; then ok "service running with a Trojan server"; else bad "service not running"; call status; fi
	r=$(call wizard '{"action":"connectivity"}')
	echo "connectivity: $r"
	check "the router reaches the internet through the Trojan server" '[ "$(jget "$r" @.ok)" = true ]'
	r=$(diag explain '{"input":"www.googlevideo.com"}')
	check "explain (running configuration): the Trojan server" '[ "$(jget "$r" @.config.source)" = running ] && [ "$(jget "$r" @.route.match.target.type)" = trojan ]'
	call stop >/dev/null; status_wait stopped 60 || bad "service not stopped"
else
	skip "service start and connectivity through the Trojan server (nftables)"
fi

echo "== mixed VLESS + Trojan: links, Use targets"
r=$(call import "$(req links "$GOOD_LINK")")
VL=$(jget "$r" '@.nodes[0].id')
check "a VLESS server next to the Trojan servers" '[ -n "$VL" ] && [ "$(get "$VL" protocol)" = vless ] && [ "$(count vless)" = 1 ]'
uci set $CONFIG.main_router.UDP="$VL"; uci commit $CONFIG
r=$(call check)
check "Default on Trojan, a rule on VLESS: valid configuration" '[ "$(jget "$r" @.ok)" = true ] && [ -n "$(jsonfilter -i "$CHECK_CONFIG" -e "@.outbounds[@.type=\"vless\"].server" | head -n 1)" ] && [ -n "$(jsonfilter -i "$CHECK_CONFIG" -e "@.outbounds[@.type=\"trojan\"].server" | head -n 1)" ]'
r=$(diag explain '{"input":"example.org:3478","network":"udp"}')
check "explain: the UDP rule goes to the VLESS server, the rest to Trojan" '[ "$(jget "$r" @.route.match.target.id)" = "$VL" ] && [ "$(jget "$r" @.route.match.target.type)" = vless ]'
both=$(printf '%s\n%s\n' "$(echo "$GOOD_LINK" | sed 's/#.*$/#Bulk%20VLESS/; s/:20443/:20441/')" "$(echo "$TROJAN_LINK" | sed 's/#.*$/#Bulk%20Trojan/; s/:20445/:20447/')")
r=$(call import "$(req links "$both")")
check "bulk import of a vless:// and a trojan:// link" '[ "$(jget "$r" @.added)" = 2 ] && [ "$(get "$(by_name "Bulk VLESS")" protocol)" = vless ] && [ "$(get "$(by_name "Bulk Trojan")" protocol)" = trojan ]'

echo "== Backup / Restore, Export / Import"
before=$(uci -q show $CONFIG | sort | md5sum | cut -d' ' -f1)
r=$(transfer backup)
BK=$(jget "$r" @.content)
check "backup of a configuration with Trojan servers" '[ "$(jget "$r" @.ok)" = true ] && [ -n "$BK" ]'
EXN=$(jget "$(transfer export "" nodes)" @.content)
check "export: Trojan entries carry protocol and password, VLESS entries the UUID" 'echo "$EXN" | grep -q "\"protocol\": *\"trojan\"" && echo "$EXN" | grep -qF "\"$TROJAN_PASSWORD\"" && echo "$EXN" | grep -q "\"protocol\": *\"vless\""'
reset_config
check "reset: no servers" '[ "$(count trojan)" = 0 ] && [ "$(count vless)" = 0 ]'
r=$(transfer import_check "$EXN")
n=$(jget "$r" @.count)
check "import check: every exported server is offered (${n})" '[ "$(jget "$r" @.ok)" = true ] && [ "$n" -ge 5 ]'
r=$(transfer import_apply "$EXN")
check "import: VLESS and Trojan servers are added" '[ "$(jget "$r" @.ok)" = true ] && [ "$(jget "$r" @.added)" = "$n" ] && [ "$(count vless)" = 2 ] && [ "$(count trojan)" -ge 3 ]'
id=$(by_name "Bulk Trojan")
ev2=$(uci -q show $CONFIG | sed -n "s/^$CONFIG\.\([^.]*\)\.tls_serverName='x.example.com'$/\1/p" | head -n 1)
check "import: a password with shell characters survives export and import as data" '[ -n "$ev2" ] && [ "$(get "$ev2" password)" = "$EVIL_PW" ]'
check "import: the Trojan server came with its password, TLS and SNI" '[ -n "$id" ] && [ "$(get "$id" password)" = "$TROJAN_PASSWORD" ] && [ "$(get "$id" tls)" = 1 ] && [ "$(get "$id" tls_serverName)" = trojan.test ] && [ "$(get "$id" type)" = sing-box ] && [ "$(get "$id" add_mode)" = 1 ]'
r=$(transfer import_apply "$EXN")
check "import again: nothing is duplicated" '[ "$(jget "$r" @.error.code)" = nothing ]'
evil=$(echo "$EXN" | sed "s/\"password\": *\"$TROJAN_PASSWORD\"/\"password\":\"\"/g")
check "the test file really differs" '[ "$evil" != "$EXN" ]'
reset_config
r=$(transfer import_apply "$evil")
check "import: Trojan entries without a password are not imported, the valid entries are" '[ -z "$(by_name "Bulk Trojan")" ] && [ -n "$(by_name "Bulk VLESS")" ] && ! uci -q show $CONFIG | grep -q "\.password=''$"'
reset_config
r=$(transfer restore_apply "$BK"); status_wait stopped 60 || true
check "restore: the configuration with the Trojan servers is back" '[ "$(jget "$r" @.ok)" = true ] && [ "$(uci -q show $CONFIG | sort | md5sum | cut -d" " -f1)" = "$before" ] && [ "$(get "$TR" password)" = "$TROJAN_PASSWORD" ]'
r=$(call check)
check "restore: the restored configuration is valid" '[ "$(jget "$r" @.ok)" = true ]'

echo "== mixed VLESS + Trojan subscriptions"
if [ -n "${SUB_URL:-}" ]; then
	sub() { call subscribe "{\"action\":\"$1\",\"id\":\"${2:-}\"}"; }
	subset() {
		uci -q delete $CONFIG.$1
		uci set $CONFIG.$1=subscribe_list
		uci set $CONFIG.$1.remark="$1"
		uci set $CONFIG.$1.url="$SUB_URL/$2"
		uci commit $CONFIG
	}
	subrun() {
		r=$(sub update "$1")
		[ "$(jget "$r" @.code)" = 0 ] || { echo "{\"status\":\"refused\",\"output\":\"$(jget "$r" @.output)\"}"; return; }
		i=0; sw=$(sub state)
		while [ "$(jget "$sw" @.busy)" = true ] && [ "$i" -lt 90 ]; do sleep 1; i=$((i + 1)); sw=$(sub state); done
		i=0; while [ -f /var/lock/$CONFIG.lock ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
		jget "$(sub state)" "@.results.$1"
	}
	rec() { jsonfilter -s "$1" -e "@.$2" 2>/dev/null; }
	group() { uci -q show $CONFIG | grep "\.group='$1'$" | cut -d. -f2; }
	gcount() { n=0; for g in $(group "$1"); do [ "$(get "$g" protocol)" = "$2" ] && n=$((n + 1)); done; echo $n; }
	reset_config
	for fmt in "plain:URL list" "b64:base64 URL list" "clash:Clash YAML" "singbox:sing-box JSON"; do
		p=${fmt%%:*}; f=${fmt#*:}
		subset "m_$p" "mixed/$p"
		r=$(subrun "m_$p")
		echo "$p: $r"
		check "mixed subscription $f: 2 VLESS + 2 Trojan servers received, the unsupported one skipped" '[ "$(rec "$r" status)" = ok ] && [ "$(rec "$r" found)" = 4 ] && [ "$(rec "$r" format)" = "$f" ]'
		check "mixed subscription $f: protocols of the nodes" '[ "$(gcount "m_$p" vless)" = 2 ] && [ "$(gcount "m_$p" trojan)" = 2 ]'
		t=""; for g in $(group "m_$p"); do [ "$(get "$g" protocol)" = trojan ] && [ "$(get "$g" tls_allowInsecure)" = 1 ] && t=$g; done
		check "mixed subscription $f: the Trojan node has password, TLS, SNI and belongs to the subscription" '[ -n "$t" ] && [ "$(get "$t" password)" = "$TROJAN_PASSWORD" ] && [ "$(get "$t" tls)" = 1 ] && [ "$(get "$t" tls_serverName)" = trojan.test ] && [ "$(get "$t" add_mode)" = 2 ] && [ "$(get "$t" type)" = sing-box ]'
	done
	# an update keeps the section ids (the routing keeps pointing to the node)
	ids_before=$(group m_plain | sort | tr '\n' ' ')
	t=""; for g in $(group m_plain); do [ "$(get "$g" protocol)" = trojan ] && [ "$(get "$g" tls_allowInsecure)" = 1 ] && t=$g; done
	routing "$t" "$t"
	r=$(subrun m_plain)
	check "update of a mixed subscription: no duplicates, the same section ids" '[ "$(group m_plain | sort | tr "\n" " ")" = "$ids_before" ] && [ "$(uci -q get $CONFIG.main_router.default_node)" = "$t" ]'
	r=$(call check)
	check "a Trojan subscription node as Default: valid configuration" '[ "$(jget "$r" @.ok)" = true ]'
	if [ "$NFT" = 1 ]; then
		r=$(call urltest_node "$(req node "$t")")
		check "Server Test of the Trojan subscription node passes" '[ "$(jget "$r" @.ok)" = true ]'
	else
		skip "Server Test of the Trojan subscription node (SO_MARK)"
	fi
	# a node deleted by the user stays deleted
	r=$(call nodes "$(req action delete id "$(for g in $(group m_b64); do [ "$(get "$g" protocol)" = trojan ] && echo "$g"; done | head -n 1)" key "")")
	r=$(subrun m_b64)
	check "a Trojan node deleted by the user is not imported again" '[ "$(gcount m_b64 trojan)" = 1 ] && [ "$(gcount m_b64 vless)" = 2 ]'
else
	echo "SUB_URL not set: subscription tests not run"
fi

reset_config
rm -f /tmp/ev11-check.log
check "nothing from a link, a subscription or a file was run as a command" '[ -z "$(ls /tmp/ev11-pwned* 2>/dev/null)" ]'
echo
echo "===== Trojan backend tests: $PASS passed, $FAIL failed, $SKIP skipped (QEMU emulation limits) ====="
[ "$FAIL" -eq 0 ]
