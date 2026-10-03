#!/bin/sh
# Easy VLESS - subscription format tests (URL list, base64, sing-box JSON).
# Not installed by any package. Run as root on a router or test system where
# easy-vless is installed, from the repository's tests/ directory:
#   sh subscription-formats-test.sh [fixture dir]    (default: ./subscription)
#
# Uses subscribe.lua's local-file mode (subscription URL = file path), so no
# network is needed. Creates temporary subscriptions named "EVTEST ..." and
# removes them and their nodes at the end. Manual nodes are checked to stay
# unchanged. Note: like every subscription update, each run ends with
# "/etc/init.d/easy_vless restart" (existing subscribe.lua behaviour).

CONFIG=easy_vless
SUB=/usr/share/easy_vless/subscribe.lua
LOG=/tmp/log/${CONFIG}.log
FX=${1:-$(dirname "$0")/subscription}
WORK=/tmp/evtest
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
eq()  { [ "$2" = "$3" ] && ok "$1 = '$3'" || bad "$1: expected '$3', got '$2'"; }

[ -f "$SUB" ] || { echo "easy-vless is not installed ($SUB missing)"; exit 2; }
[ -d "$FX" ] || { echo "fixture dir $FX not found"; exit 2; }
rm -rf $WORK; mkdir -p $WORK; cp "$FX"/* $WORK/

wait_lock() { i=0; while [ -f /var/lock/${CONFIG}_subscribe.lock ] && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done; }
sub_id()   { uci -X show $CONFIG | grep "=subscribe_list" | cut -d. -f2 | cut -d= -f1 | while read s; do [ "$(uci -q get $CONFIG.$s.remark)" = "$1" ] && echo $s; done | head -1; }
nodes_of() { uci -X show $CONFIG | grep "\.group='$1'$" | cut -d. -f2; }
count_of() { nodes_of "$1" | grep -c .; }
node_by()  { for n in $(nodes_of "$1"); do [ "$(uci -q get $CONFIG.$n.remarks)" = "$2" ] && echo $n; done | head -1; }
get()      { uci -q get $CONFIG.$1.$2; }
manual_fp() { uci -X show $CONFIG | grep -E "^$CONFIG\.[^.]+=nodes$" | cut -d. -f2 | cut -d= -f1 | while read n; do [ "$(get $n add_mode)" = "2" ] || uci -X show $CONFIG.$n; done | md5sum | cut -d' ' -f1; }

# run <group> <fixture file>: creates/updates the subscription and runs a manual update
run() {
	local s=$(sub_id "$1")
	if [ -z "$s" ]; then
		s=$(uci add $CONFIG subscribe_list); uci set $CONFIG.$s.remark="$1"
	fi
	uci set $CONFIG.$s.url="$WORK/$2"; uci commit $CONFIG
	LOGMARK=$(wc -l < $LOG 2>/dev/null || echo 0)
	wait_lock
	lua $SUB start "$(sub_id "$1")" manual >/dev/null 2>&1
	wait_lock
	RUNLOG=$(tail -n +$((LOGMARK + 1)) $LOG 2>/dev/null)
}
logged() { echo "$RUNLOG" | grep -q "$1"; }

MANUAL_BEFORE=$(manual_fp)

echo "----- 1. single VLESS URL -----"
run "EVTEST url1" url-single.txt
eq "url1 nodes" "$(count_of 'EVTEST url1')" 1
n=$(node_by "EVTEST url1" "URL Single"); eq "url1 address" "$(get "$n" address)" 198.51.100.60

echo "----- 2. multiple VLESS URLs (plain + base64) -----"
run "EVTEST url3" url-multi.txt;        eq "plain list nodes" "$(count_of 'EVTEST url3')" 3
run "EVTEST url3b" url-multi-base64.txt; eq "base64 list nodes" "$(count_of 'EVTEST url3b')" 3
logged "Subscription format: base64 URL list" && ok "format reported: base64 URL list" || bad "format not reported"

echo "----- 3/5/9. sing-box JSON, one VLESS + direct, TUN/DNS/route with Windows rule_set paths -----"
run "EVTEST sb1" singbox-one.json
logged "Subscription format: sing-box JSON" && ok "format detected: sing-box JSON" || bad "format not detected"
eq "sb1 nodes (direct ignored)" "$(count_of 'EVTEST sb1')" 1
n=$(node_by "EVTEST sb1" proxy)
eq "protocol" "$(get "$n" protocol)" vless
eq "address" "$(get "$n" address)" 198.51.100.10
eq "port" "$(get "$n" port)" 443
eq "uuid" "$(get "$n" uuid)" 00000000-0000-4000-8000-000000000001
eq "flow" "$(get "$n" flow)" xtls-rprx-vision
eq "tls" "$(get "$n" tls)" 1
eq "reality" "$(get "$n" reality)" 1
eq "reality_publicKey" "$(get "$n" reality_publicKey)" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
eq "reality_shortId" "$(get "$n" reality_shortId)" 0123456789abcdef
eq "tls_serverName" "$(get "$n" tls_serverName)" www.example.com
eq "utls" "$(get "$n" utls)" 1
eq "fingerprint" "$(get "$n" fingerprint)" chrome
eq "transport" "$(get "$n" transport)" tcp
for foreign in 'rule_sets' 'C:\\' 'tun-in' 'dns_proxy' 'ip.example.net' '10.0.0.1/30' 'auto_detect_interface'; do
	uci -X show $CONFIG | grep -qF "$foreign" && bad "foreign config '$foreign' copied into UCI" || ok "foreign config '$foreign' not copied"
done
run "EVTEST sb1b" singbox-one-base64.txt; eq "base64-wrapped JSON nodes" "$(count_of 'EVTEST sb1b')" 1

echo "----- 4. sing-box JSON, several VLESS outbounds (+ direct/block/selector) -----"
run "EVTEST sbm" singbox-multi.json
eq "multi nodes" "$(count_of 'EVTEST sbm')" 4
for name in "NL Reality" "DE WS TLS" "VLESS 3" "VLESS 4"; do [ -n "$(node_by 'EVTEST sbm' "$name")" ] && ok "node '$name' present" || bad "node '$name' missing"; done
n=$(node_by "EVTEST sbm" "DE WS TLS")
eq "ws transport" "$(get "$n" transport)" ws
eq "ws_path" "$(get "$n" ws_path)" /ws
eq "ws_host" "$(get "$n" ws_host)" de.example.com
eq "alpn" "$(get "$n" alpn)" "h2,http/1.1"
eq "fingerprint" "$(get "$n" fingerprint)" firefox
eq "ws_maxEarlyData" "$(get "$n" ws_maxEarlyData)" 2048
n=$(node_by "EVTEST sbm" "VLESS 3"); eq "grpc serviceName" "$(get "$n" grpc_serviceName)" gsvc
n=$(node_by "EVTEST sbm" "VLESS 4"); eq "httpupgrade path" "$(get "$n" httpupgrade_path)" /up; eq "httpupgrade tls" "$(get "$n" tls)" 0
run "EVTEST sbm" singbox-multi.json
eq "no duplicates after a second update" "$(count_of 'EVTEST sbm')" 4

echo "----- JSON array of outbounds -----"
run "EVTEST arr" singbox-outbound-array.json; eq "array nodes" "$(count_of 'EVTEST arr')" 1

echo "----- 6. unsupported outbounds -----"
run "EVTEST uns" singbox-unsupported.json
eq "unsupported: VLESS imported" "$(count_of 'EVTEST uns')" 1
logged "imported 1, skipped 4; skipped types: hysteria2, shadowsocks, trojan, wireguard (endpoint)" && ok "skip summary reported" || bad "skip summary: $(echo "$RUNLOG" | grep 'sing-box JSON:')"

echo "----- 7. malformed JSON keeps the existing nodes -----"
run "EVTEST sb1" malformed-json.txt
logged "invalid sing-box JSON" && ok "malformed JSON reported" || bad "malformed JSON not reported"
eq "sb1 nodes kept" "$(count_of 'EVTEST sb1')" 1

echo "----- 8. zero supported outbounds -----"
run "EVTEST zero" singbox-zero.json
eq "zero: nodes" "$(count_of 'EVTEST zero')" 0
logged "imported 0, skipped 1" && logged "No supported VLESS outbound" && ok "zero import reported (not claimed as success)" || bad "zero import not reported"

echo "----- 10. node deleted by the user stays deleted, section ids are stable (0.9.0) -----"
# node list actions of rpcd "nodes" (subscribe.lua + nodes.lua): one JSON object
node_action() { wait_lock; lua $SUB "$@" 2>/dev/null; wait_lock; }
jget() { jsonfilter -s "$1" -e "$2" 2>/dev/null; }
run "EVTEST del" url-multi.txt
eq "del: nodes" "$(count_of 'EVTEST del')" 3
id1=$(node_by "EVTEST del" "URL 1"); id2=$(node_by "EVTEST del" "URL 2"); id3=$(node_by "EVTEST del" "URL 3")
run "EVTEST del" url-multi.txt
eq "same list again: URL 1 keeps its section id" "$(node_by 'EVTEST del' 'URL 1')" "$id1"
eq "same list again: URL 3 keeps its section id" "$(node_by 'EVTEST del' 'URL 3')" "$id3"
# a server that is still used is not deleted
uci set $CONFIG.evtestgrp=nodes; uci set $CONFIG.evtestgrp.protocol=_urltest; uci set $CONFIG.evtestgrp.remarks='EVTEST group'
uci add_list $CONFIG.evtestgrp.urltest_node="$id1"; uci commit $CONFIG
out=$(node_action delete "$id1")
eq "delete of a used server: refused" "$(jget "$out" '@.ok')" false
eq "delete of a used server: reason" "$(jget "$out" '@.error')" used
eq "delete of a used server: still there" "$(get "$id1" protocol)" vless
uci -q delete $CONFIG.evtestgrp; uci commit $CONFIG
out=$(node_action delete "$id2")
eq "delete: ok" "$(jget "$out" '@.ok')" true
eq "delete: remembered by the subscription" "$(jget "$out" '@.excluded')" true
eq "delete: nodes left" "$(count_of 'EVTEST del')" 2
get "$(sub_id 'EVTEST del')" excluded_node | grep -q "URL 2" && ok "excluded_node stored in the subscription" || bad "excluded_node missing: $(get "$(sub_id 'EVTEST del')" excluded_node)"
get "$(sub_id 'EVTEST del')" excluded_node | grep -q "00000000-0000-4000-8000" && bad "excluded_node contains the UUID" || ok "excluded_node does not contain the UUID"
run "EVTEST del" url-multi.txt
eq "update: the deleted node is not imported again" "$(count_of 'EVTEST del')" 2
[ -z "$(node_by 'EVTEST del' 'URL 2')" ] && ok "URL 2 stays deleted" || bad "URL 2 came back"
eq "update: URL 1 keeps its section id" "$(node_by 'EVTEST del' 'URL 1')" "$id1"
# the provider reorders the list, renames the deleted node and adds one
run "EVTEST del" url-multi-reordered.txt
eq "reordered list: nodes" "$(count_of 'EVTEST del')" 3
[ -z "$(node_by 'EVTEST del' 'URL 2 renamed')" ] && ok "renamed and moved: still deleted" || bad "renamed node came back"
[ -n "$(node_by 'EVTEST del' 'URL 4')" ] && ok "new node imported" || bad "new node missing"
eq "reordered list: URL 1 keeps its section id" "$(node_by 'EVTEST del' 'URL 1')" "$id1"
eq "reordered list: URL 3 keeps its section id" "$(node_by 'EVTEST del' 'URL 3')" "$id3"
# a failed update neither deletes nodes nor forgets the deleted one
run "EVTEST del" malformed-json.txt
eq "failed update: nodes kept" "$(count_of 'EVTEST del')" 3
get "$(sub_id 'EVTEST del')" excluded_node | grep -q . && ok "failed update: the deleted node is still remembered" || bad "failed update dropped excluded_node"
# "Delete all nodes": the plan changes nothing
before_all=$(uci -X show $CONFIG | md5sum)
out=$(node_action delete_all_plan)
eq "delete_all_plan: ok" "$(jget "$out" '@.ok')" true
[ "$(jget "$out" '@.counts.subscription')" -ge 3 ] 2>/dev/null && ok "delete_all_plan counts the subscription servers" || bad "delete_all_plan counts: $out"
eq "delete_all_plan: configuration unchanged" "$(uci -X show $CONFIG | md5sum)" "$before_all"
# restore: the node is imported again
out=$(node_action restore "$(sub_id 'EVTEST del')")
eq "restore: ok" "$(jget "$out" '@.ok')" true
eq "restore: one node" "$(jget "$out" '@.restored')" 1
run "EVTEST del" url-multi-reordered.txt
eq "after restore: nodes" "$(count_of 'EVTEST del')" 4
[ -n "$(node_by 'EVTEST del' 'URL 2 renamed')" ] && ok "restored node imported again" || bad "restored node missing"

echo "----- manual nodes untouched -----"
eq "manual nodes fingerprint" "$(manual_fp)" "$MANUAL_BEFORE"

echo "----- cleanup -----"
for g in "EVTEST url1" "EVTEST url3" "EVTEST url3b" "EVTEST sb1" "EVTEST sb1b" "EVTEST sbm" "EVTEST arr" "EVTEST uns" "EVTEST zero" "EVTEST del"; do
	for n in $(nodes_of "$g"); do uci -q delete $CONFIG.$n; done
	s=$(sub_id "$g"); [ -n "$s" ] && uci -q delete $CONFIG.$s
done
uci commit $CONFIG; rm -rf $WORK
eq "manual nodes fingerprint after cleanup" "$(manual_fp)" "$MANUAL_BEFORE"

echo "===== PASS: $PASS  FAIL: $FAIL ====="
[ $FAIL -eq 0 ]
