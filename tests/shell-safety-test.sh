#!/bin/sh
# Easy VLESS 1.0 - values of the configuration are data, never shell code.
#
#   sh tests/shell-safety-test.sh      (static checks, CI "checks" job)
#
# A node name comes from a subscription, a setting may come from a restored
# backup. Both travel through shell text on their way to sing-box:
#   app_acl.lua  writes "<acl>/var" (sourced by nftables.sh) and
#                "acl_node_<flag>" (read with eval by app.sh, its words then
#                handed to eval_set_val)
#   app.sh check passes the settings as name=value arguments to eval_set_val
# The test runs the real app_acl.lua (with a stand-in for the UCI API) and
# the real eval_set_val on hostile values and looks for the one thing that
# must not happen: a command of the value being run.
#
# Tools: sh, lua5.1 (or lua).

set -u
cd "$(dirname "$0")/.." || exit 2

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

LUA=$(command -v lua5.1 || command -v lua || true)
[ -n "$LUA" ] || { echo "FAIL: no lua5.1 / lua"; exit 1; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
MARK="$W/RAN"

# ---------------------------------------------------------------- eval_set_val
sed -n '/^eval_set_val() {/,/^}/p' root/usr/share/easy_vless/utils.sh > "$W/fn.sh"
check "eval_set_val found in utils.sh" '[ -s "$W/fn.sh" ]'
. "$W/fn.sh"

run_args() {
	local flag="" node="" redir_port="" remote_dns_doh="" empty="" quoted="" nftset=""
	eval_set_val "$@"
	echo "flag=[$flag] node=[$node] redir_port=[$redir_port] doh=[$remote_dns_doh] empty=[$empty] quoted=[$quoted] nftset=[$nftset]"
}

out=$(run_args flag=acl_default node=main_router redir_port=1041 remote_dns_doh=https://1.1.1.1/dns-query 'empty=""' 'quoted="value"' 'nftset=4#inet#easy_vless#a,6#inet#easy_vless#b')
check "plain and quoted arguments are assigned ($out)" \
	'[ "$out" = "flag=[acl_default] node=[main_router] redir_port=[1041] doh=[https://1.1.1.1/dns-query] empty=[] quoted=[value] nftset=[4#inet#easy_vless#a,6#inet#easy_vless#b]" ]'

out=$(run_args "remote_dns_doh=https://x/dns-query;touch\${IFS}$MARK.1" "node=\$(touch $MARK.2)" "flag=\`touch $MARK.3\`" "redir_port=1;touch $MARK.4" "\$(touch $MARK.5)" "touch $MARK.6" "bad;name=1" "9x=1")
check "a value with ';', \$( ) or backquotes is kept as text, nothing runs" '[ -z "$(ls "$W" | grep RAN)" ]'
check "the hostile setting arrives unchanged as data" 'echo "$out" | grep -qF "doh=[https://x/dns-query;touch\${IFS}$MARK.1]"'

# ---------------------------------------------------------------- app_acl.lua
# hostile values: a node name from a subscription, settings from a backup
cat > "$W/stub.lua" <<EOF
local W, MARK = "$W", "$MARK"
local values = {
	["@global[0]"] = { node = "srv", enabled = "1", localhost_proxy = "1", client_proxy = "1",
		remote_dns = "1.1.1.1:53",
		remote_dns_doh = 'https://x/dns-query" ; touch ' .. MARK .. '.doh ; "',
		remote_dns_detour = "remote \$(touch " .. MARK .. ".detour)",
		remote_dns_query_strategy = "UseIPv4\`touch " .. MARK .. ".strategy\`",
		node_socks_port = "1070" },
	["@global_forwarding[0]"] = { tcp_redir_ports = "1:65535", udp_redir_ports = "1:65535",
		tcp_no_redir_ports = 'disable" ; touch ' .. MARK .. '.ports ; "' },
	srv = { [".name"] = "srv", [".type"] = "nodes", protocol = "vless", type = "sing-box",
		remarks = NAME },
}
local port = 1040
local api = {
	jsonc = { stringify = function() return "{}" end },
	sys = { call = function(cmd) return os.execute(cmd) end },
	fs = {}, uci = {},
	i18n = { translatef = function(s) return s end },
	log = function() end,
	TMP_ACL_PATH = W .. "/acl",
	uci_get_c = function(section, option)
		local s = values[section]
		if option == nil then return s end
		return s and s[option] or nil
	end,
	uci_set_c = function() end, uci_del_c = function() end, uci_save_c = function() end,
	uci_foreach_c = function() end,
	get_new_port = function() port = port + 1 return port end,
	parseDNS = function(v) return (v:match("^([^:]+)")), (v:match(":(%d+)$") or 53) end,
	set_cache_var = function() end,
	iprange = function() return false end,
	ip_or_mac = function() return nil end,
}
package.preload["luci.easy_vless.api"] = function() return api end
EOF

gen() { # gen <node name>: run app_acl.lua for a main node with this name
	rm -rf "$W/acl"; mkdir -p "$W/acl"
	NAME="$1" "$LUA" -e "NAME = os.getenv('NAME') dofile('$W/stub.lua') dofile('root/usr/share/easy_vless/app_acl.lua')" >/dev/null 2>"$W/err" \
		|| { bad "app_acl.lua failed: $(cat "$W/err")"; return 1; }
}

# what nftables.sh does with "<acl>/var", what app.sh does with "acl_node_<flag>"
consume() {
	(
		. "$W/acl/acl_default/var"
		echo "node_remarks=[$node_remarks] node=[$node] redir_port=[$redir_port] flag=[$flag]"
	) > "$W/var.out" 2>"$W/var.err"
	(
		_var=$(cat "$W/acl/acl_node_acl_default")
		f() {
			eval local ${_var}
			local remote_dns_doh="" remote_dns_detour="" remote_dns_query_strategy="" node="" flag="" redir_port=""
			eval_set_val ${_var}
			echo "flag=[$flag] node=[$node] doh=[$remote_dns_doh] detour=[$remote_dns_detour] strategy=[$remote_dns_query_strategy]"
		}
		f
	) > "$W/args.out" 2>"$W/args.err"
}

gen 'Germany 🇩🇪 #1 (fast)' && consume
check "an ordinary node name survives as it is ($(cat "$W/var.out"))" 'grep -qF "node_remarks=[Germany 🇩🇪 #1 (fast)] node=[srv]" "$W/var.out" && [ ! -s "$W/var.err" ]'
check "the run arguments are read without an error ($(cat "$W/args.out"))" 'grep -q "^flag=\[acl_default\] node=\[srv\] " "$W/args.out" && [ ! -s "$W/args.err" ]'
check "hostile settings did not run anything" '[ -z "$(ls "$W" | grep RAN)" ]'
check "a setting is one word: nothing of it became a second argument" 'grep -qF "detour=[remote(touch" "$W/args.out" && grep -qF "strategy=[UseIPv4touch" "$W/args.out"'

for name in \
	"x\$(touch $MARK.n1)" \
	"x\`touch $MARK.n2\`" \
	"x\"; touch $MARK.n3; echo \"" \
	"x'; touch $MARK.n4; echo '" \
	"x\\\"; touch $MARK.n5; \\\"" \
	"a * b" \
	"x
touch $MARK.n6"
do
	gen "$name" && consume
	check "hostile node name is only text: $(printf '%s' "$name" | tr '\n' ' ' | cut -c1-40)" '[ -z "$(ls "$W" | grep RAN)" ] && [ ! -s "$W/var.err" ] && [ ! -s "$W/args.err" ] && grep -q "node=\[srv\]" "$W/var.out"'
done
gen 'a * b' && consume
check "a '*' in a node name is not expanded to file names" 'grep -qF "node_remarks=[a * b]" "$W/var.out"'

echo
echo "===== shell safety: $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
