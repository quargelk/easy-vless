-- Easy VLESS - diagnostics (0.9.0): unit / regression test of
-- root/usr/lib/lua/luci/easy_vless/diagnose.lua with a stock Lua 5.1.
--
--   lua5.1 tests/diagnose-test.lua      (static checks, CI "checks" job)
--
-- The nft fixture has the rules nftables.sh loads (TPROXY mode, LAN and
-- router traffic, DNS redirect). Covered: forwarding diagnostics (ok, partly
-- working, broken - each with its concrete reason; stopped is not an error),
-- nslookup output parsing, DNS diagnostics, the connection panel as an
-- aggregator (one unavailable part does not hide the others).

package.path = "root/usr/lib/lua/?.lua;" .. package.path
local D = require "luci.easy_vless.diagnose"

local pass, fail = 0, 0
local function check(msg, cond)
	if cond then pass = pass + 1 print("PASS: " .. msg)
	else fail = fail + 1 print("FAIL: " .. msg) end
end
local function find(checks, id)
	for _, c in ipairs(checks) do
		if c.id == id then return c end
	end
	return {}
end
local function copy(t)
	local o = {}
	for k, v in pairs(t) do o[k] = v end
	return o
end

-- ---------------------------------------------------------------- nft fixture
local function nft_table(opts)
	opts = opts or {}
	local t = {}
	local function w(s) t[#t + 1] = s end
	w("table inet easy_vless {")
	w("\tset ev_local {\n\t\ttype ipv4_addr\n\t\tflags interval,timeout\n\t\tauto-merge\n\t\telements = { 192.168.1.1 }\n\t}")
	if not opts.no_direct_set then
		w("\tset ev_direct {\n\t\ttype ipv4_addr\n\t\tflags interval,timeout\n\t\tauto-merge\n\t\telements = { 0.0.0.0/8, 10.0.0.0/8,\n\t\t\t     100.64.0.0/10, 127.0.0.0/8,\n\t\t\t     192.168.0.0/16 }\n\t}")
	end
	w("\tset ev_vps {\n\t\ttype ipv4_addr\n\t\tflags interval,timeout\n\t\tauto-merge\n\t\telements = { 203.0.113.5 timeout 1d expires 23h }\n\t}")
	w("\tset ev_wan {\n\t\ttype ipv4_addr\n\t\tflags interval,timeout\n\t\tauto-merge\n\t}")
	w("\tchain dstnat {\n\t\ttype nat hook prerouting priority dstnat - 1; policy accept;\n\t\tip saddr @ev_direct jump EV_DNS")
	if opts.redirect then w("\t\tip daddr != @ev_direct ip protocol tcp counter packets 3 bytes 180 jump EV_NAT") end
	w("\t}")
	w("\tchain mangle_prerouting {\n\t\ttype filter hook prerouting priority mangle - 1; policy accept;")
	w("\t\tmeta nfproto ipv4 meta l4proto tcp socket transparent 1 meta mark set 0x45560000 counter packets 0 bytes 0 accept comment \"EV_SOCKET\"")
	if not opts.no_lan_jump then
		w("\t\tip daddr != @ev_direct ip protocol udp counter packets 9 bytes 900 jump EV_MANGLE")
		if not opts.redirect then w("\t\tip daddr != @ev_direct ip protocol tcp counter packets 9 bytes 900 jump EV_MANGLE") end
	end
	if opts.ipv6 then w("\t\tip6 daddr != @ev_direct6 meta nfproto { ipv6 } counter packets 0 bytes 0 jump EV_MANGLE_V6") end
	w("\t}")
	w("\tchain mangle_output {\n\t\ttype route hook output priority mangle - 1; policy accept;")
	w("\t\tip daddr != @ev_direct ip protocol tcp counter packets 1 bytes 60 jump EV_OUTPUT_MANGLE comment \"EV_OUTPUT_MANGLE\"")
	w("\t\tip daddr != @ev_direct ip protocol udp counter packets 1 bytes 60 jump EV_OUTPUT_MANGLE comment \"EV_OUTPUT_MANGLE\"")
	w("\t}")
	w("\tchain nat_output {\n\t\ttype nat hook output priority -1; policy accept;")
	w("\t\toif \"lo\" meta l4proto udp udp dport 53 counter packets 4 bytes 240 redirect to :1053 comment \"EV_DNS\"")
	if opts.redirect then w("\t\tip daddr != @ev_direct ip protocol tcp counter packets 1 bytes 60 jump EV_OUTPUT_NAT") end
	w("\t}")
	w("\tchain EV_DNS {")
	if not opts.no_dns_redirect then
		w("\t\tmeta l4proto udp udp dport 53 counter packets 4 bytes 240 redirect to :1053 comment \"default\"")
		w("\t\tmeta l4proto tcp tcp dport 53 counter packets 0 bytes 0 redirect to :1053 comment \"default\"")
	end
	w("\t}")
	w("\tchain EV_RULE {\n\t\tcounter packets 5 bytes 300 meta mark set ct mark\n\t\tmeta mark 0x45560000 counter packets 0 bytes 0 return\n\t}")
	w("\tchain EV_MANGLE {\n\t\tip daddr @ev_vps counter packets 0 bytes 0 return\n\t\tct direction reply counter packets 0 bytes 0 return")
	if not opts.redirect and not opts.no_tcp then
		w("\t\tip protocol tcp counter packets 5 bytes 300 jump EV_RULE comment \"default\"")
		w("\t\tip protocol tcp counter packets 5 bytes 300 meta mark set 0x45560000 tproxy ip to :" .. (opts.port or "1041") .. " comment \"default\"")
	end
	if not opts.no_udp then
		w("\t\tip protocol udp counter packets 5 bytes 300 jump EV_RULE comment \"default\"")
		w("\t\tip protocol udp counter packets 5 bytes 300 meta mark set 0x45560000 tproxy ip to :" .. (opts.port or "1041") .. " comment \"default\"")
	end
	w("\t}")
	w("\tchain EV_OUTPUT_MANGLE {\n\t\tip daddr @ev_vps counter packets 0 bytes 0 return\n\t}")
	if opts.redirect then
		w("\tchain EV_NAT {\n\t\tip daddr @ev_vps counter packets 0 bytes 0 return\n\t\tip protocol tcp counter packets 3 bytes 180 redirect to :1041 comment \"default\"\n\t}")
		w("\tchain EV_OUTPUT_NAT {\n\t\tip daddr @ev_vps counter packets 0 bytes 0 return\n\t}")
	end
	if opts.ipv6 then
		w("\tchain EV_MANGLE_V6 {\n\t\tmeta l4proto tcp counter packets 0 bytes 0 meta mark set 0x45560000 tproxy ip6 to :1041\n\t}")
		w("\tchain EV_OUTPUT_MANGLE_V6 {\n\t}")
	end
	w("}")
	return table.concat(t, "\n")
end

local SET = { tcp_proxy_way = "tproxy", tcp_redir_ports = "1:65535", udp_redir_ports = "1:65535", ipv6_tproxy = "0", client_proxy = "1", localhost_proxy = "1", dns_redirect = "1" }
local RULE4 = "0:\tfrom all lookup local\n998:\tfrom all fwmark 0x45560000 lookup 998\n32766:\tfrom all lookup main\n"
local ROUTE4 = "local default dev lo scope host\n"
local function state(o)
	local st = { running = true, settings = copy(SET), nft = nft_table(o and o.nft), rule4 = RULE4, route4 = ROUTE4, fw4 = true, redir_port = 1041 }
	for k, v in pairs(o or {}) do
		if k == "settings" then for a, b in pairs(v) do st.settings[a] = b end
		elseif k ~= "nft" then st[k] = v end
	end
	return st
end

-- ---------------------------------------------------------------- nft parsing
local p = D.parse_nft(nft_table())
check("nft: chains found", p.chains.EV_MANGLE and p.chains.EV_RULE and p.chains.mangle_prerouting and p.chains.EV_DNS and not p.chains.EV_NAT)
check("nft: sets and element counts across lines (" .. tostring(p.sets.ev_direct.elements) .. ")", p.sets.ev_direct.elements == 5 and p.sets.ev_vps.elements == 1 and p.sets.ev_wan.elements == 0)
check("nft: no table text", next(D.parse_nft(nil).chains) == nil)

-- ---------------------------------------------------------------- forwarding
local f = D.forwarding(state())
local nf, tp = f.groups.nftables, f.groups.tproxy
check("healthy TPROXY: everything ok (" .. f.status .. ")", f.status == "ok" and nf.status == "ok" and tp.status == "ok")
check("healthy: table, chains, sets", find(nf.checks, "table").code == "table_ok" and find(nf.checks, "chains").code == "chains_ok" and find(nf.checks, "sets").code == "sets_ok")
check("healthy: policy routing with the fwmark and table", find(tp.checks, "policy").code == "policy_ok" and find(tp.checks, "policy").mark == "0x45560000" and find(tp.checks, "policy").table == "998")
check("healthy: TCP and UDP redirected with TPROXY to the sing-box port", find(tp.checks, "tcp").code == "redirect_ok" and find(tp.checks, "tcp").method == "TPROXY" and find(tp.checks, "tcp").port == "1041" and find(tp.checks, "udp").status == "ok")
check("healthy: LAN and router interception, DNS redirect", find(tp.checks, "lan").code == "lan_ok" and find(tp.checks, "router").code == "router_ok" and find(tp.checks, "dns_redirect").code == "dns_redirect_ok")
check("healthy: IPv6 TProxy off is 'off', not an error", find(tp.checks, "ipv6").status == "off" and find(tp.checks, "ipv6").code == "ipv6_off")

f = D.forwarding(state({ nft = { no_udp = true } }))
tp = f.groups.tproxy
check("UDP rule missing: TPROXY fails, partly working, reason named", tp.status == "fail" and tp.partial == true and find(tp.checks, "udp").code == "redirect_rule_missing" and find(tp.checks, "udp").chain == "EV_MANGLE" and find(tp.checks, "tcp").status == "ok")
f = D.forwarding(state({ settings = { udp_redir_ports = "disable" } , nft = { no_udp = true } }))
tp = f.groups.tproxy
check("UDP forwarding switched off: 'off' with the reason, not a failure", find(tp.checks, "udp").status == "off" and find(tp.checks, "udp").code == "proto_off" and tp.status == "ok")

f = D.forwarding({ running = true, settings = copy(SET), nft = nil, rule4 = RULE4, route4 = ROUTE4, fw4 = true })
check("running without the nft table: fail 'table missing'", f.groups.nftables.status == "fail" and find(f.groups.nftables.checks, "table").code == "table_missing" and f.status == "fail")
f = D.forwarding(state({ nft = { no_lan_jump = true } }))
check("forwarding chain not hooked: LAN interception fails with the chain", find(f.groups.tproxy.checks, "lan").code == "lan_jump_missing" and find(f.groups.tproxy.checks, "lan").chain == "mangle_prerouting")
f = D.forwarding(state({ rule4 = "0:\tfrom all lookup local\n" }))
check("ip rule missing: policy routing fails", find(f.groups.tproxy.checks, "policy").code == "policy_rule_missing" and f.groups.tproxy.status == "fail" and not f.groups.tproxy.partial)
f = D.forwarding(state({ route4 = "" }))
check("local route missing in table 998", find(f.groups.tproxy.checks, "policy").code == "policy_route_missing")
f = D.forwarding(state({ nft = { port = "1099" } }))
check("rule points to another port than sing-box listens on", find(f.groups.tproxy.checks, "tcp").code == "redirect_port_mismatch" and find(f.groups.tproxy.checks, "tcp").rule_port == "1099")
f = D.forwarding(state({ nft = { no_direct_set = true } }))
check("a set is missing", find(f.groups.nftables.checks, "sets").code == "sets_missing" and find(f.groups.nftables.checks, "sets").items == "ev_direct")
f = D.forwarding(state({ settings = { client_proxy = "0" }, nft = { no_lan_jump = true } }))
check("Client Proxy off: LAN interception 'off', router still ok", find(f.groups.tproxy.checks, "lan").code == "lan_off" and find(f.groups.tproxy.checks, "router").status == "ok")
f = D.forwarding(state({ settings = { tcp_proxy_way = "redirect" }, nft = { redirect = true } }))
tp = f.groups.tproxy
check("REDIRECT mode: TCP by REDIRECT in EV_NAT, UDP by TPROXY", f.status == "ok" and find(tp.checks, "tcp").method == "REDIRECT" and find(tp.checks, "udp").method == "TPROXY" and f.method == "redirect")
f = D.forwarding(state({ settings = { tcp_proxy_way = "redirect" } }))
check("REDIRECT mode configured but the NAT chains are missing", find(f.groups.nftables.checks, "chains").code == "chains_missing" and find(f.groups.nftables.checks, "chains").items == "EV_NAT, EV_OUTPUT_NAT")
f = D.forwarding(state({ settings = { ipv6_tproxy = "1" }, nft = { ipv6 = true }, rule6 = "998:\tfrom all fwmark 0x45560000 lookup 998\n", route6 = "local default dev lo metric 1024\n" }))
check("IPv6 TProxy on and complete", find(f.groups.tproxy.checks, "ipv6").code == "ipv6_ok")
f = D.forwarding(state({ settings = { ipv6_tproxy = "1" }, nft = { ipv6 = true }, rule6 = "", route6 = "" }))
check("IPv6 TProxy on but the ip -6 rule is missing", find(f.groups.tproxy.checks, "ipv6").code == "ipv6_broken" and find(f.groups.tproxy.checks, "ipv6").what == "ip -6 rule")
f = D.forwarding(state({ settings = { tcp_no_redir_ports = "25,465", udp_redir_ports = "53,443" } }))
check("port exceptions are listed", find(f.groups.tproxy.checks, "exceptions").items == "TCP 25,465" and find(f.groups.tproxy.checks, "ports").items == "UDP 53,443")
f = D.forwarding(state({ nft = { no_dns_redirect = true } }))
check("DNS redirect rule missing although configured: warning", find(f.groups.tproxy.checks, "dns_redirect").status == "warn")
f = D.forwarding(state({ nft = { no_dns_redirect = true }, settings = { dns_redirect = "0" } }))
check("DNS redirect off by configuration", find(f.groups.tproxy.checks, "dns_redirect").status == "off")

f = D.forwarding({ running = false, settings = copy(SET), nft = nil, rule4 = "0:\tfrom all lookup local\n", route4 = "", fw4 = true })
check("stopped and clean: 'off', not a failure", f.status == "off" and find(f.groups.nftables.checks, "table").code == "stopped")
f = D.forwarding({ running = false, settings = copy(SET), nft = nft_table(), rule4 = RULE4, route4 = ROUTE4, fw4 = true })
check("stopped but the table and ip rule are still there: leftover warning", f.status == "warn" and find(f.groups.nftables.checks, "table").code == "table_leftover" and find(f.groups.tproxy.checks, "policy").code == "policy_leftover")
f = D.forwarding({ running = false, settings = copy(SET), nft = "Error: No such file or directory\nlist table inet easy_vless\n           ^^^^^^^^^^\n", rule4 = "", route4 = "", fw4 = true })
check("nft's error text (it repeats the table name) is not taken for the table", f.status == "off" and find(f.groups.nftables.checks, "table").code == "stopped")
f = D.forwarding({ running = true, settings = copy(SET), fw4 = false })
check("fw4 missing", find(f.groups.nftables.checks, "fw4").code == "fw4_missing" and f.status == "fail")
f = D.forwarding({ running = true, settings = copy(SET), fw4 = true, nft_error = "Operation not permitted" })
check("nft cannot be asked: reported as such", find(f.groups.nftables.checks, "fw4").code == "nft_unavailable")

-- ---------------------------------------------------------------- nslookup
local BB_OK = "Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\nNon-authoritative answer:\nName:\texample.org\nAddress: 93.184.216.34\n\nNon-authoritative answer:\nName:\texample.org\nAddress: 2606:2800:220:1:248:1893:25c8:1946\n"
local r = D.parse_nslookup(BB_OK)
check("nslookup: addresses, without the resolver's own address", r.status == "ok" and #r.addresses == 2 and r.addresses[1] == "93.184.216.34" and r.addresses[2] == "2606:2800:220:1:248:1893:25c8:1946")
r = D.parse_nslookup("Server:\t\t127.0.0.1\nAddress:\t127.0.0.1#53\n\nName:\texample.org\nAddress: 198.18.0.12\n")
check("nslookup: bind format, FakeDNS address recognised", r.status == "ok" and r.addresses[1] == "198.18.0.12" and D.is_fake(r.addresses[1]) and not D.is_fake("93.184.216.34") and D.is_fake("fc00::12") and not D.is_fake("fc00:4000::1"))
check("nslookup: timeout", D.parse_nslookup(";; connection timed out; no servers could be reached\n").status == "timeout")
r = D.parse_nslookup("Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\n** server can't find nope.invalid: NXDOMAIN\n")
check("nslookup: NXDOMAIN", r.status == "nxdomain" and r.rcode == "NXDOMAIN")
check("nslookup: SERVFAIL", D.parse_nslookup("Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\n** server can't find example.org: SERVFAIL\n").status == "servfail")
check("nslookup: REFUSED", D.parse_nslookup("Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\n** server can't find example.org: REFUSED\n").status == "refused")
check("nslookup: answered without a record", D.parse_nslookup("Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\n*** Can't find example.org: No answer\n").status == "noanswer")
check("nslookup: TXT record counts as an answer", D.parse_nslookup("Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\nNon-authoritative answer:\nexample.org\ttext = \"v=spf1 -all\"\n").status == "ok")
check("nslookup: empty output", D.parse_nslookup("").status == "error" and D.parse_nslookup(nil).status == "error")

-- ---------------------------------------------------------------- DNS diagnostics
local DSET = { dns_redirect = "1", remote_fakedns = "1", remote_dns_query_strategy = "UseIPv4", ipv6_tproxy = "0" }
local remote = { kind = "remote", tag = "remote", type = "udp", address = "1.1.1.1", port = 53, detour = { kind = "server", id = "srv" } }
local fakeip = { kind = "fakeip", tag = "remote_fakeip" }
local direct = { kind = "direct", tag = "direct", type = "udp", address = "192.0.2.53", port = 53, detour = { kind = "direct" } }
local function plan(server, aaaa)
	return { a = { certain = true, match = { kind = "rule", action = "route", server = server } },
		aaaa = { certain = true, match = aaaa or { kind = "rule", action = "predefined" } } }
end
local function dns(o)
	local st = { running = true, domain = "example.org", settings = copy(DSET), forwarding = { dns_redirect = true }, plan = plan(fakeip),
		lookup = { a = { status = "ok", addresses = { "198.18.0.9" }, ms = 3 }, aaaa = { status = "noanswer", addresses = {} } },
		probe = { direct = { status = "ok", ms = 12, server = "192.0.2.53" }, remote = { status = "ok", ms = 80, server = "1.1.1.1", via = "srv" } } }
	for k, v in pairs(o or {}) do
		if k == "settings" then for a, b in pairs(v) do st.settings[a] = b end else st[k] = v end
	end
	return D.dns(st)
end
local d = dns()
check("DNS healthy with FakeDNS (" .. d.status .. ")", d.status == "ok" and find(d.checks, "resolve").code == "resolve_ok_fake" and find(d.checks, "fakedns").code == "fake_ok")
check("DNS: which server answers, IPv4 only, both upstreams reachable with latency", find(d.checks, "server").kind == "fakeip" and find(d.checks, "ipmode").code == "ipv4_only"
	and find(d.checks, "direct_dns").code == "upstream_ok" and find(d.checks, "remote_dns").ms == 80 and find(d.checks, "hijack").code == "hijack_ok")
check("DNS: what the router cannot see is stated, not claimed", find(d.checks, "client_dns").status == "info" and find(d.checks, "client_dns").code == "client_secure_dns_unknown")
d = dns({ probe = { direct = { status = "ok", ms = 12, server = "192.0.2.53" }, remote = { status = "timeout", server = "1.1.1.1", via = "srv" } } })
check("Remote DNS unreachable: fail with the server and the reason", d.status == "fail" and find(d.checks, "remote_dns").code == "upstream_unreachable" and find(d.checks, "remote_dns").reason == "timeout" and find(d.checks, "remote_dns").server == "1.1.1.1")
d = dns({ probe = { direct = { status = "timeout", server = "192.0.2.53" }, remote = { status = "ok", ms = 80, server = "1.1.1.1" } } })
check("Direct DNS unreachable", find(d.checks, "direct_dns").code == "upstream_unreachable" and find(d.checks, "direct_dns").which == "direct")
d = dns({ probe = { remote = { skipped = "fakeip" } } })
check("a probe that was not possible is 'info', not ok", find(d.checks, "remote_dns").status == "info" and find(d.checks, "remote_dns").code == "probe_skipped")
d = dns({ lookup = { a = { status = "ok", addresses = { "93.184.216.34" }, ms = 20 }, aaaa = { status = "noanswer", addresses = {} } } })
check("FakeDNS conflict: a real address although FakeDNS is expected", d.status == "warn" and find(d.checks, "fakedns").code == "fake_expected_real")
d = dns({ plan = plan(remote) })
check("FakeDNS conflict: a FakeDNS address although the rule uses Remote DNS", find(d.checks, "fakedns").code == "fake_unexpected")
d = dns({ plan = plan(direct), lookup = { a = { status = "ok", addresses = { "5.255.255.70" }, ms = 9 }, aaaa = { status = "noanswer", addresses = {} } } })
check("Direct DNS domain: real address, FakeDNS not used for it", d.status == "ok" and find(d.checks, "resolve").code == "resolve_ok" and find(d.checks, "fakedns").code == "fake_not_for_domain" and find(d.checks, "server").kind == "direct")
d = dns({ lookup = { a = { status = "timeout", addresses = {} } } })
check("resolution failed: fail with the reason", d.status == "fail" and find(d.checks, "resolve").code == "resolve_failed" and find(d.checks, "resolve").reason == "timeout")
d = dns({ lookup = { a = { status = "ok", addresses = { "198.18.0.9" } }, aaaa = { status = "ok", addresses = { "2606:2800::1" } } } })
check("IP mode mismatch: IPv6 answer although IPv4 only is configured", find(d.checks, "ipmode").code == "ipv6_answer_unexpected" and d.status == "warn")
d = dns({ plan = plan(remote, { kind = "rule", action = "route", server = remote }), settings = { remote_dns_query_strategy = "UseIP" },
	lookup = { a = { status = "ok", addresses = { "93.184.216.34" } }, aaaa = { status = "ok", addresses = { "2606:2800::1" } } } })
check("IP mode mismatch: proxied domain gets IPv6 addresses but IPv6 TProxy is off", find(d.checks, "ipmode").code == "ipv6_answer_no_tproxy")
d = dns({ plan = plan(remote, { kind = "rule", action = "route", server = remote }), settings = { remote_dns_query_strategy = "UseIP", ipv6_tproxy = "1" },
	lookup = { a = { status = "ok", addresses = { "93.184.216.34" } }, aaaa = { status = "ok", addresses = { "2606:2800::1" } } } })
check("dual stack with IPv6 TProxy on: ok", find(d.checks, "ipmode").code == "dual_stack")
d = dns({ forwarding = { dns_redirect = false }, settings = { dns_redirect = "0" }, dnsmasq = { forwards_to_singbox = true } })
check("DNS redirect off: devices with their own DNS server bypass it (warning)", find(d.checks, "hijack").code == "hijack_off_router_only" and find(d.checks, "hijack").status == "warn")
d = dns({ forwarding = { dns_redirect = false }, settings = { dns_redirect = "0" }, dnsmasq = { forwards_to_singbox = false } })
check("DNS not handed to Easy VLESS at all: fail", find(d.checks, "hijack").code == "dns_not_forwarded" and d.status == "fail")
d = dns({ forwarding = { dns_redirect = false } })
check("DNS redirect configured but its rule is missing", find(d.checks, "hijack").code == "hijack_missing")
d = dns({ settings = { remote_dns_client_ip = "203.0.113.0/24" } })
check("EDNS Client Subnet shown", find(d.checks, "ecs").subnet == "203.0.113.0/24")
d = dns({ plan = { a = { certain = false, match = { kind = "final", action = "route", server = remote } } } , lookup = { a = { status = "ok", addresses = { "1.2.3.4" } } } })
check("uncertain DNS rule (geodata) is marked", find(d.checks, "server").code == "dns_server_uncertain" and find(d.checks, "server").status == "warn")
d = D.dns({ running = false, lookup = { a = { status = "ok", addresses = { "93.184.216.34" }, ms = 15 } } })
check("stopped: the router's own DNS is checked, Easy VLESS DNS is 'off'", d.status == "ok" and find(d.checks, "service").code == "dns_stopped" and find(d.checks, "resolve").code == "resolve_ok_system")

-- ---------------------------------------------------------------- connection panel
local STATUS = { enabled = true, running = true, pid = "1234", singbox_bin = "/usr/bin/sing-box", singbox_version = "1.12.22", singbox_backend = true, rss_kb = 40000 }
local function conn(o)
	local parts = { status = copy(STATUS), env = { ok = true }, forwarding = D.forwarding(state()), dns = dns(), localhost_proxy = "1",
		node = { kind = "server", id = "srv", name = "Finland", test = { ok = true, delay = 120, age = 60 } },
		routing = { mode = "shunt", rules_active = 4, rules_total = 4, default = "srv", dangling = {}, config_rules = 4, config_outbounds = 5 },
		internet = { ok = true, http_code = "204", ms = 300, url = "https://www.gstatic.com/generate_204" } }
	for k, v in pairs(o or {}) do parts[k] = v end
	if o and o.drop then parts[o.drop] = nil parts.drop = nil end
	return D.connection(parts)
end
local function item(c, id)
	for _, it in ipairs(c.items) do
		if it.id == id then return it end
	end
	return {}
end
local c = conn()
local order = {}
for _, it in ipairs(c.items) do order[#order + 1] = it.id .. "=" .. it.status end
check("panel: seven items in order, all ok (" .. table.concat(order, " ") .. ")", table.concat(order, " ") == "core=ok dns=ok nftables=ok tproxy=ok vless=ok routing=ok internet=ok" and c.status == "ok")
check("panel: items carry the checks of the diagnostics they aggregate", #item(c, "tproxy").checks >= 5 and find(item(c, "tproxy").checks, "policy").code == "policy_ok"
	and find(item(c, "dns").checks, "resolve").code == "resolve_ok_fake" and find(item(c, "core").checks, "process").pid == "1234")
check("panel: internet through the proxy when Localhost Proxy is on", find(item(c, "internet").checks, "https").code == "internet_ok_proxy")
c = conn({ localhost_proxy = "0" })
check("panel: internet directly when Localhost Proxy is off", find(item(c, "internet").checks, "https").code == "internet_ok_direct")

c = conn({ forwarding = D.forwarding(state({ nft = { no_udp = true } })) })
check("panel: TPROXY partly works - only that item fails", item(c, "tproxy").status == "fail" and item(c, "tproxy").partial == true and item(c, "nftables").status == "ok" and item(c, "core").status == "ok" and c.status == "fail")
c = conn({ forwarding = { unavailable = "nft: Operation not permitted" } })
check("panel: an unavailable subsystem is shown on its own, the others keep their result",
	item(c, "nftables").unavailable == true and item(c, "tproxy").unavailable == true and item(c, "nftables").checks[1].reason == "nft: Operation not permitted" and item(c, "dns").status == "ok" and item(c, "core").status == "ok")
check("panel: an unavailable part does not make the whole panel 'failed'", c.status == "ok")
c = conn({ drop = "dns" })
check("panel: a missing part is 'unavailable', not ok", item(c, "dns").unavailable == true)
c = conn({ status = { enabled = true, running = false, singbox_bin = "/usr/bin/sing-box", singbox_backend = true } })
check("panel: main switch on but sing-box not running", find(item(c, "core").checks, "process").code == "enabled_not_running" and item(c, "core").status == "fail")
c = conn({ status = { enabled = false, running = false, singbox_bin = "/usr/bin/sing-box", singbox_backend = true } })
check("panel: switched off is 'off'", find(item(c, "core").checks, "process").code == "switched_off" and find(item(c, "core").checks, "process").status == "off")
c = conn({ status = { enabled = true, running = false, singbox_bin = "" } })
check("panel: sing-box not installed", find(item(c, "core").checks, "binary").code == "singbox_missing")
c = conn({ env = { ok = false, kind = "env", detail = "Missing required nftables kernel modules: kmod-nft-tproxy" } })
check("panel: a failed start guard is reported with its text", find(item(c, "core").checks, "environment").code == "env_error" and find(item(c, "core").checks, "environment").detail:find("kmod%-nft%-tproxy") ~= nil)
c = conn({ node = { kind = "server", id = "srv", name = "Finland", test = { ok = false, error_kind = "timeout", age = 30 } } })
check("panel: VLESS - the last Server Test failed", item(c, "vless").status == "fail" and find(item(c, "vless").checks, "test").error_kind == "timeout")
c = conn({ node = { kind = "server", id = "srv", name = "Finland" } })
check("panel: VLESS - not tested yet is 'info', not ok and not failed", find(item(c, "vless").checks, "test").code == "test_none" and item(c, "vless").status == "ok")
c = conn({ node = { kind = "missing", id = "gone" } })
check("panel: VLESS - the selected node does not exist", find(item(c, "vless").checks, "node").code == "node_missing" and item(c, "vless").status == "fail")
c = conn({ node = { kind = "group", id = "g", name = "Fastest", members = 3 } })
check("panel: VLESS - URL Test group", find(item(c, "vless").checks, "node").code == "node_group" and find(item(c, "vless").checks, "test").code == "test_group")
c = conn({ routing = { mode = "shunt", rules_active = 4, rules_total = 4, dangling = { "main_router.PROXY" }, config_rules = 4 } })
check("panel: routing - a target points to a missing node", item(c, "routing").status == "fail" and find(item(c, "routing").checks, "references").items == "main_router.PROXY")
c = conn({ routing = { mode = "shunt", rules_active = 3, rules_total = 4, dangling = {}, config_rules = 4 } })
check("panel: routing - saved rules differ from the running configuration", find(item(c, "routing").checks, "config").code == "config_differs" and item(c, "routing").status == "warn")
c = conn({ internet = { ok = false, http_code = "000", curl_code = 28, url = "https://www.gstatic.com/generate_204" } })
check("panel: internet failed, through the proxy", item(c, "internet").status == "fail" and find(item(c, "internet").checks, "https").through == "proxy" and find(item(c, "internet").checks, "https").curl_code == 28)
c = conn({ busy = true })
check("panel: 'an operation is running' is passed on", c.busy == true)

print(string.format("\n===== diagnostics: %d passed, %d failed =====", pass, fail))
os.exit(fail == 0 and 0 or 1)
