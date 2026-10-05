-- Easy VLESS 0.9.0 - diagnostics: turns the real state of the router (the
-- nftables table of Easy VLESS, policy routing, the settings, the running
-- sing-box configuration, answers of DNS lookups) into a list of checks with
-- a status and the concrete reason.
--
--   status  ok | warn | fail | off | info
--           off  = not active by configuration (not an error)
--           info = something the router cannot verify, said so explicitly
--   code    what was found; LuCI translates it (view/easy_vless/diagnostics.js)
--
-- Pure functions over plain data: no UCI, no shell. The data is collected by
-- /usr/share/easy_vless/diag.lua; tests/diagnose-test.lua feeds fixtures.

local X = require "luci.easy_vless.explain"

local M = {}

M.FWMARK = "0x45560000"
M.ROUTE_TABLE = "998"

local RANK = { fail = 4, warn = 3, ok = 2, info = 1, off = 0 }

local function add(list, id, status, code, params)
	local c = params or {}
	c.id, c.status, c.code = id, status, code
	list[#list + 1] = c
	return c
end

-- A copy of a result in which no table occurs twice. The JSON encoder of the
-- router (luci.jsonc) writes a table it has already seen as null, so a value
-- shared by two places - the DNS server of the plan and of the "server"
-- check, the addresses of two checks - would silently lose its second copy
-- ("DNS used: unknown" next to a green mark). Everything diag.lua prints goes
-- through this.
function M.plain(v, depth)
	if type(v) ~= "table" then return v end
	depth = depth or 0
	if depth > 40 then return nil end
	local out = {}
	for k, x in pairs(v) do
		out[k] = M.plain(x, depth + 1)
	end
	return out
end

-- Worst status of a list of checks ("off" only if nothing else is there).
function M.worst(checks)
	local best
	for _, c in ipairs(checks) do
		if c.status ~= "info" and (best == nil or RANK[c.status] > RANK[best]) then best = c.status end
	end
	return best or "info"
end

local function on(v, default)
	if v == nil or v == "" then v = default end
	return v == "1" or v == 1 or v == true
end

-- ---------------------------------------------------------------- nft text

-- "nft list table inet easy_vless" as { chains = { name = { lines } },
-- sets = { name = { elements = n | nil } } }.
function M.parse_nft(text)
	local res = { chains = {}, sets = {} }
	if type(text) ~= "string" then return res end
	local cur, kind
	for line in text:gmatch("[^\n]+") do
		local l = line:match("^%s*(.-)%s*$")
		local chain = l:match("^chain%s+([%w_]+)%s*{")
		local set = l:match("^set%s+([%w_]+)%s*{")
		if chain then
			cur, kind = chain, "chain"
			res.chains[chain] = {}
		elseif set then
			cur, kind = set, "set"
			res.sets[set] = { elements = 0 }
		elseif l == "}" then
			cur, kind = nil, nil
		elseif cur and kind == "chain" then
			table.insert(res.chains[cur], l)
		elseif cur and kind == "set" then
			if l:find("elements%s*=") then
				res.sets[cur].has_elements = true
			end
			if res.sets[cur].has_elements then
				local body = l:gsub("^.*{", "")
				for _ in body:gmatch("[%x:%./%-]+[^,}]*") do
					res.sets[cur].elements = res.sets[cur].elements + 1
				end
			end
		end
	end
	return res
end

local function chain_has(nft, chain, ...)
	local lines = nft.chains[chain]
	if not lines then return false end
	local pats = { ... }
	for _, l in ipairs(lines) do
		local ok = true
		for _, p in ipairs(pats) do
			if not l:find(p, 1, true) then ok = false break end
		end
		if ok then return true, l end
	end
	return false
end

-- ---------------------------------------------------------------- forwarding

-- st = {
--   running   sing-box of Easy VLESS runs
--   settings  { tcp_proxy_way, tcp_redir_ports, udp_redir_ports,
--               tcp_no_redir_ports, udp_no_redir_ports, ipv6_tproxy,
--               client_proxy, localhost_proxy, dns_redirect }
--   nft       text of "nft list table inet easy_vless" (nil = no table)
--   nft_error why nft could not be asked (nil = it could)
--   rule4 / rule6    text of "ip [-6] rule show"
--   route4 / route6  text of "ip [-6] route show table 998"
--   fw4       the fw4 command exists
--   redir_port  the transparent proxy port of the running configuration
-- }
-- Returns { status, checks = { ... }, groups = { nftables, tproxy } } where a
-- group is { status, checks }.
function M.forwarding(st)
	local s = st.settings or {}
	local nftc, tpc = {}, {}
	local way = (s.tcp_proxy_way == "redirect") and "redirect" or "tproxy"
	local ipv6 = on(s.ipv6_tproxy, "0")
	local lan, router = on(s.client_proxy, "1"), on(s.localhost_proxy, "1")
	local has_table = type(st.nft) == "string" and st.nft:find("table inet easy_vless {", 1, true) ~= nil
	local nft = M.parse_nft(st.nft)

	-- firewall backend
	if st.fw4 == false then
		add(nftc, "fw4", "fail", "fw4_missing")
	elseif st.nft_error then
		add(nftc, "fw4", "fail", "nft_unavailable", { detail = st.nft_error })
	else
		add(nftc, "fw4", "ok", "fw4_ok")
	end

	if not st.running then
		if has_table then
			add(nftc, "table", "warn", "table_leftover")
		else
			add(nftc, "table", "off", "stopped")
		end
		local leftover = (st.rule4 or ""):find("fwmark " .. M.FWMARK, 1, true)
			or ((st.route4 or ""):find("local", 1, true) and (st.route4 or ""):find("dev lo", 1, true))
		add(tpc, "policy", leftover and "warn" or "off", leftover and "policy_leftover" or "stopped")
		return { status = M.worst(nftc) == "fail" and "fail" or (has_table or leftover) and "warn" or "off", running = false,
			groups = { nftables = { status = M.worst(nftc), checks = nftc }, tproxy = { status = M.worst(tpc), checks = tpc } } }
	end

	-- table, chains, sets
	if not has_table then
		add(nftc, "table", "fail", "table_missing")
	else
		add(nftc, "table", "ok", "table_ok")
		local need = { "EV_RULE", "EV_MANGLE", "EV_OUTPUT_MANGLE", "EV_DNS" }
		if way == "redirect" then
			need[#need + 1] = "EV_NAT"
			need[#need + 1] = "EV_OUTPUT_NAT"
		end
		if ipv6 then
			need[#need + 1] = "EV_MANGLE_V6"
			need[#need + 1] = "EV_OUTPUT_MANGLE_V6"
		end
		local missing = {}
		for _, c in ipairs(need) do
			if not nft.chains[c] then missing[#missing + 1] = c end
		end
		if #missing > 0 then
			add(nftc, "chains", "fail", "chains_missing", { items = table.concat(missing, ", ") })
		else
			add(nftc, "chains", "ok", "chains_ok", { count = #need })
		end
		local sets = { "ev_local", "ev_direct", "ev_vps", "ev_wan" }
		missing = {}
		for _, n in ipairs(sets) do
			if not nft.sets[n] then missing[#missing + 1] = n end
		end
		if #missing > 0 then
			add(nftc, "sets", "fail", "sets_missing", { items = table.concat(missing, ", ") })
		elseif nft.sets.ev_direct.elements == 0 then
			-- private and LAN ranges go here: empty means LAN traffic would be proxied
			add(nftc, "sets", "warn", "direct_set_empty")
		else
			add(nftc, "sets", "ok", "sets_ok", { direct = nft.sets.ev_direct.elements, vps = nft.sets.ev_vps.elements })
		end
	end

	-- policy routing: marked packets are delivered locally (to sing-box)
	local rule_ok = (st.rule4 or ""):find("fwmark " .. M.FWMARK, 1, true) ~= nil
	local route_ok = (st.route4 or ""):find("local", 1, true) ~= nil and (st.route4 or ""):find("dev lo", 1, true) ~= nil
	if rule_ok and route_ok then
		add(tpc, "policy", "ok", "policy_ok", { mark = M.FWMARK, table = M.ROUTE_TABLE })
	elseif not rule_ok then
		add(tpc, "policy", "fail", "policy_rule_missing", { mark = M.FWMARK, table = M.ROUTE_TABLE })
	else
		add(tpc, "policy", "fail", "policy_route_missing", { table = M.ROUTE_TABLE })
	end

	local port = st.redir_port and tostring(st.redir_port) or nil
	local function redirects(chain, proto)
		-- "tproxy to :1041" / "tproxy ip to :1041" / "redirect to :1041"
		local lines = nft.chains[chain] or {}
		for _, l in ipairs(lines) do
			if l:find(proto, 1, true) and (l:find("tproxy", 1, true) or l:find("redirect to", 1, true)) then
				local p = l:match("to :(%d+)")
				return true, p
			end
		end
		return false
	end

	-- LAN devices (prerouting) and the router itself (output)
	local jump_pre = chain_has(nft, "mangle_prerouting", "jump EV_MANGLE")
	local jump_out = chain_has(nft, "mangle_output", "jump EV_OUTPUT_MANGLE")
	local jump_nat = chain_has(nft, "dstnat", "jump EV_NAT")
	local jump_nat_out = chain_has(nft, "nat_output", "jump EV_OUTPUT_NAT")

	local function proto_check(proto, id)
		local ports = s[proto .. "_redir_ports"]
		if ports == "disable" then
			add(tpc, id, "off", "proto_off", { proto = proto:upper() })
			return "off"
		end
		local chain = (proto == "tcp" and way == "redirect") and "EV_NAT" or "EV_MANGLE"
		local found, p = redirects(chain, proto)
		local method = (proto == "tcp" and way == "redirect") and "REDIRECT" or "TPROXY"
		if not found then
			add(tpc, id, (lan or router) and "fail" or "off", (lan or router) and "redirect_rule_missing" or "proxy_off",
				{ proto = proto:upper(), chain = chain, method = method })
			return (lan or router) and "fail" or "off"
		end
		if port and p and p ~= port then
			add(tpc, id, "fail", "redirect_port_mismatch", { proto = proto:upper(), rule_port = p, port = port })
			return "fail"
		end
		add(tpc, id, "ok", "redirect_ok", { proto = proto:upper(), method = method, port = p,
			ports = (ports and ports ~= "" and ports ~= "1:65535") and ports or nil })
		return "ok"
	end
	local tcp = proto_check("tcp", "tcp")
	local udp = proto_check("udp", "udp")

	if not lan then
		add(tpc, "lan", "off", "lan_off")
	elseif (way == "redirect" and jump_nat and jump_pre) or (way ~= "redirect" and jump_pre) then
		add(tpc, "lan", "ok", "lan_ok")
	else
		add(tpc, "lan", "fail", "lan_jump_missing", { chain = (way == "redirect" and not jump_nat) and "dstnat" or "mangle_prerouting" })
	end
	if not router then
		add(tpc, "router", "off", "router_off")
	elseif jump_out and (way ~= "redirect" or jump_nat_out) then
		add(tpc, "router", "ok", "router_ok")
	else
		add(tpc, "router", "fail", "router_jump_missing", { chain = (way == "redirect" and not jump_nat_out) and "nat_output" or "mangle_output" })
	end

	-- IPv6
	if not ipv6 then
		add(tpc, "ipv6", "off", "ipv6_off")
	else
		local r6 = (st.rule6 or ""):find("fwmark " .. M.FWMARK, 1, true) ~= nil
		local t6 = (st.route6 or ""):find("local", 1, true) ~= nil
		local j6 = chain_has(nft, "mangle_prerouting", "jump EV_MANGLE_V6")
		if r6 and t6 and j6 then
			add(tpc, "ipv6", "ok", "ipv6_ok")
		else
			add(tpc, "ipv6", "fail", "ipv6_broken", { what = (not j6) and "EV_MANGLE_V6" or (not r6) and "ip -6 rule" or "ip -6 route" })
		end
	end

	-- port exceptions (configuration, shown so that "why is port X direct" has an answer)
	local ex = {}
	for _, proto in ipairs({ "tcp", "udp" }) do
		local nr = s[proto .. "_no_redir_ports"]
		if nr and nr ~= "" and nr ~= "disable" then ex[#ex + 1] = proto:upper() .. " " .. nr end
	end
	if #ex > 0 then
		add(tpc, "exceptions", "info", "port_exceptions", { items = table.concat(ex, "; ") })
	end
	local limited = {}
	for _, proto in ipairs({ "tcp", "udp" }) do
		local rp = s[proto .. "_redir_ports"]
		if rp and rp ~= "" and rp ~= "1:65535" and rp ~= "disable" then limited[#limited + 1] = proto:upper() .. " " .. rp end
	end
	if #limited > 0 then
		add(tpc, "ports", "info", "ports_limited", { items = table.concat(limited, "; ") })
	end

	-- DNS redirect of port 53
	local dns_redir = chain_has(nft, "EV_DNS", "redirect to")
	if dns_redir then
		add(tpc, "dns_redirect", "ok", "dns_redirect_ok")
	else
		add(tpc, "dns_redirect", on(s.dns_redirect, "1") and "warn" or "off", on(s.dns_redirect, "1") and "dns_redirect_missing" or "dns_redirect_off")
	end

	local groups = { nftables = { status = M.worst(nftc), checks = nftc }, tproxy = { status = M.worst(tpc), checks = tpc } }
	-- "partly works": one of TCP / UDP is redirected, the other is not
	if groups.tproxy.status == "fail" and (tcp == "ok" or udp == "ok") and rule_ok and route_ok then
		groups.tproxy.partial = true
	end
	local all = {}
	for _, c in ipairs(nftc) do all[#all + 1] = c end
	for _, c in ipairs(tpc) do all[#all + 1] = c end
	return { status = M.worst(all), running = true, tcp = tcp, udp = udp, method = way, groups = groups }
end

-- ---------------------------------------------------------------- DNS

-- Output of BusyBox / bind nslookup as { status, addresses, rcode }:
--   ok        at least one address (or a record for non-address queries)
--   noanswer  the server answered without a record of that type
--   nxdomain  the name does not exist
--   servfail  the server could not resolve (its upstream failed)
--   refused   the server refused the query
--   timeout   no answer from the server
--   error     anything else (output kept in "detail")
function M.parse_nslookup(out)
	local res = { addresses = {} }
	if type(out) ~= "string" or out == "" then
		res.status = "error"
		return res
	end
	local low = out:lower()
	if low:find("timed out", 1, true) or low:find("no servers could be reached", 1, true) then
		res.status = "timeout"
		return res
	end
	-- skip the "Server:/Address:" header of the resolver itself
	local body = out
	local p = out:find("\n%s*\n")
	if p and out:sub(1, p):lower():find("server", 1, true) then body = out:sub(p) end
	for addr in body:gmatch("[Aa]ddress[^:\n]*:%s*([%x:%.]+)") do
		addr = addr:gsub("^(%d+%.%d+%.%d+%.%d+):%d+$", "%1"):lower()
		if X.parse_ip(addr) then
			res.addresses[#res.addresses + 1] = addr
		end
	end
	local rcode = out:match("[Cc]an't find [^:\n]*:%s*([%w ]+)") or out:match("server can't find [^:\n]*:%s*([%w ]+)")
	if rcode then res.rcode = rcode:match("^%s*(.-)%s*$") end
	local has_record = #res.addresses > 0 or body:find("text%s*=") or body:find("\tname = ") or body:find("canonical name", 1, true) or body:find("mail exchanger", 1, true)
	if has_record then
		res.status = "ok"
	elseif low:find("nxdomain", 1, true) then
		res.status = "nxdomain"
	elseif low:find("servfail", 1, true) then
		res.status = "servfail"
	elseif low:find("refused", 1, true) then
		res.status = "refused"
	elseif low:find("no answer", 1, true) or low:find("non-authoritative answer", 1, true) or low:find("name:", 1, true) then
		res.status = "noanswer"
	else
		res.status = "error"
		res.detail = out:sub(1, 300)
	end
	return res
end

-- an address of the FakeDNS ranges (198.18.0.0/16, fc00::/18)
local function is_fake(addr)
	local ip = X.parse_ip(addr)
	return ip ~= nil and X.is_fake_ip(ip)
end
M.is_fake = is_fake

local function has_v6(addresses)
	for _, a in ipairs(addresses or {}) do
		if a:find(":", 1, true) then return true end
	end
	return false
end

-- st = {
--   running, domain
--   settings   { dns_redirect, remote_fakedns, remote_dns_query_strategy,
--                direct_dns_query_strategy, ipv6_tproxy, remote_dns_client_ip }
--   forwarding { dns_redirect = true | false }  EV_DNS redirects port 53
--   plan       { a, aaaa, other } = explain.dns() results (which rule and
--              server the running configuration uses for this domain)
--   lookup     { a, aaaa } answers the router's DNS gave (parse_nslookup
--              + ms), the path a LAN device uses
--   probe      { direct, remote } reachability of the two upstream servers
--              (parse_nslookup + ms, server), nil when not probed
--   dnsmasq    { noresolv, upstream } the main dnsmasq: is it handed to
--              Easy VLESS (forwards to sing-box)
-- }
function M.dns(st)
	local s = st.settings or {}
	local checks = {}
	if not st.running then
		add(checks, "service", "off", "dns_stopped")
		if st.lookup and st.lookup.a then
			local l = st.lookup.a
			add(checks, "resolve", l.status == "ok" and "ok" or "fail", l.status == "ok" and "resolve_ok_system" or "resolve_failed",
				{ reason = l.status, addresses = l.addresses, ms = l.ms, rcode = l.rcode })
		end
		return { status = M.worst(checks), running = false, checks = checks }
	end

	local plan = st.plan or {}
	local pa = plan.a and plan.a.match
	local fake_expected = pa and pa.server and pa.server.kind == "fakeip"

	-- what answers
	if pa then
		local kind = pa.action == "predefined" and "blocked" or (pa.server and pa.server.kind or "unknown")
		if kind == "unknown" then
			-- the rule names a DNS server the configuration does not have (or an
			-- action this module does not know): that is not a working state
			add(checks, "server", "warn", "dns_server_unknown", { kind = kind, tag = pa.server and pa.server.tag, action = pa.action })
		else
			add(checks, "server", plan.a.certain == false and "warn" or "ok", plan.a.certain == false and "dns_server_uncertain" or "dns_server",
				{ kind = kind, server = pa.server, client_subnet = pa.client_subnet })
		end
	else
		add(checks, "server", "info", "dns_plan_unavailable")
	end

	-- the answer LAN devices get
	local la, l6 = st.lookup and st.lookup.a, st.lookup and st.lookup.aaaa
	if la then
		if la.status == "ok" then
			local fake = false
			for _, a in ipairs(la.addresses) do
				if is_fake(a) then fake = true end
			end
			add(checks, "resolve", "ok", fake and "resolve_ok_fake" or "resolve_ok", { addresses = la.addresses, ms = la.ms })
			if pa and fake ~= (fake_expected and true or false) then
				add(checks, "fakedns", "warn", fake and "fake_unexpected" or "fake_expected_real", { addresses = la.addresses })
			elseif fake then
				add(checks, "fakedns", "ok", "fake_ok")
			else
				add(checks, "fakedns", on(s.remote_fakedns, "0") and "info" or "off", on(s.remote_fakedns, "0") and "fake_not_for_domain" or "fake_off")
			end
		elseif la.status == "noanswer" and pa and pa.action == "predefined" then
			add(checks, "resolve", "ok", "resolve_blocked_by_rule")
		else
			add(checks, "resolve", "fail", "resolve_failed", { reason = la.status, rcode = la.rcode, detail = la.detail,
				server_kind = pa and pa.server and pa.server.kind })
		end
	end

	-- IPv4 / IPv6 mode
	local p6 = plan.aaaa and plan.aaaa.match
	if l6 then
		local got6 = l6.status == "ok" and has_v6(l6.addresses)
		if p6 and p6.action == "predefined" then
			add(checks, "ipmode", got6 and "warn" or "ok", got6 and "ipv6_answer_unexpected" or "ipv4_only", { addresses = got6 and l6.addresses or nil })
		elseif got6 then
			local real6 = false
			for _, a in ipairs(l6.addresses) do
				if a:find(":", 1, true) and not is_fake(a) then real6 = true end
			end
			if real6 and not on(s.ipv6_tproxy, "0") and p6 and p6.server and p6.server.kind ~= "direct" then
				add(checks, "ipmode", "warn", "ipv6_answer_no_tproxy", { addresses = l6.addresses })
			else
				add(checks, "ipmode", "ok", "dual_stack", { addresses = l6.addresses })
			end
		else
			add(checks, "ipmode", "ok", "no_ipv6_record")
		end
	end

	-- upstream servers
	local pr = st.probe or {}
	local function upstream(id, p, label)
		if not p then return end
		if p.skipped then
			add(checks, id, "info", "probe_skipped", { which = label, reason = p.skipped })
		elseif p.status == "timeout" or p.status == "servfail" or p.status == "refused" or p.status == "error" then
			add(checks, id, "fail", "upstream_unreachable", { which = label, server = p.server, reason = p.status, via = p.via })
		else
			add(checks, id, "ok", "upstream_ok", { which = label, server = p.server, ms = p.ms, via = p.via })
		end
	end
	upstream("direct_dns", pr.direct, "direct")
	upstream("remote_dns", pr.remote, "remote")

	-- is DNS of the LAN handed to Easy VLESS at all
	local f = st.forwarding or {}
	if f.dns_redirect then
		add(checks, "hijack", "ok", "hijack_ok")
	elseif on(s.dns_redirect, "1") then
		add(checks, "hijack", "warn", "hijack_missing")
	else
		local d = st.dnsmasq or {}
		if d.forwards_to_singbox then
			add(checks, "hijack", "warn", "hijack_off_router_only")
		else
			add(checks, "hijack", "fail", "dns_not_forwarded")
		end
	end
	-- what a router cannot see
	add(checks, "client_dns", "info", "client_secure_dns_unknown")
	if s.remote_dns_client_ip and s.remote_dns_client_ip ~= "" then
		add(checks, "ecs", "info", "ecs_on", { subnet = s.remote_dns_client_ip })
	end

	return { status = M.worst(checks), running = true, checks = checks }
end

-- ---------------------------------------------------------------- connection

-- The single panel. Every item is built from a result that exists anyway:
--   core      app.sh status + the start guards (app.sh env_check)
--   dns       M.dns() of a probe domain
--   nftables  M.forwarding().groups.nftables
--   tproxy    M.forwarding().groups.tproxy
--   vless     the selected node and its last Server Test (test.sh results)
--   routing   references of the saved configuration (nodes.lua dangling) and
--             the running configuration (rule and outbound counts)
--   internet  HTTPS request from the router (rpcd "wizard connectivity")
-- p = { status, env, forwarding, dns, node, routing, internet, busy }
-- A part that could not be collected is passed as { unavailable = reason }
-- and shown as "unavailable" on its own, without failing the others.
function M.connection(p)
	local items = {}
	local function item(id, checks)
		items[#items + 1] = { id = id, status = M.worst(checks), checks = checks }
		return items[#items]
	end
	local function unavailable(id, part)
		items[#items + 1] = { id = id, status = "info", unavailable = true,
			checks = { { id = id, status = "info", code = "unavailable", reason = part and part.unavailable or "no data" } } }
	end
	local st = p.status or {}
	local running = st.running and true or false

	-- Core
	local c = {}
	if not st.singbox_bin or st.singbox_bin == "" then
		add(c, "binary", "fail", "singbox_missing")
	elseif not st.singbox_backend then
		add(c, "binary", "fail", "backend_missing")
	else
		add(c, "binary", "ok", "singbox_ok", { version = st.singbox_version })
	end
	if p.env and p.env.ok == false then
		add(c, "environment", "fail", "env_error", { kind = p.env.kind, detail = p.env.detail })
	elseif p.env and p.env.ok then
		add(c, "environment", "ok", "env_ok")
	end
	if running then
		add(c, "process", "ok", "running", { pid = st.pid, rss_kb = st.rss_kb })
	elseif st.enabled then
		add(c, "process", "fail", "enabled_not_running")
	else
		add(c, "process", "off", "switched_off")
	end
	item("core", c)

	-- DNS
	if p.dns and p.dns.checks then
		items[#items + 1] = { id = "dns", status = p.dns.status, checks = p.dns.checks }
	else
		unavailable("dns", p.dns)
	end

	-- nftables / TPROXY
	if p.forwarding and p.forwarding.groups then
		local g = p.forwarding.groups
		items[#items + 1] = { id = "nftables", status = g.nftables.status, checks = g.nftables.checks }
		items[#items + 1] = { id = "tproxy", status = g.tproxy.status, checks = g.tproxy.checks, partial = g.tproxy.partial }
	else
		unavailable("nftables", p.forwarding)
		unavailable("tproxy", p.forwarding)
	end

	-- VLESS
	c = {}
	local n = p.node
	if not n then
		unavailable("vless", nil)
	else
		if n.kind == "none" then
			add(c, "node", st.enabled and "fail" or "off", "no_node")
		elseif n.kind == "missing" then
			add(c, "node", "fail", "node_missing", { id = n.id })
		elseif n.kind == "direct" then
			add(c, "node", "off", "no_proxy_target")
		else
			add(c, "node", "ok", n.kind == "group" and "node_group" or "node_server", { id = n.id, name = n.name, members = n.members, protocol = n.protocol })
			local t = n.test
			if n.kind == "group" then
				add(c, "test", "info", "test_group")
			elseif not t then
				add(c, "test", "info", "test_none")
			elseif t.ok then
				add(c, "test", "ok", "test_passed", { delay = t.delay, age = t.age })
			else
				add(c, "test", "fail", "test_failed", { error_kind = t.error_kind, error = t.error, age = t.age })
			end
		end
		item("vless", c)
	end

	-- Routing
	c = {}
	local r = p.routing
	if not r then
		unavailable("routing", nil)
	else
		if r.dangling and #r.dangling > 0 then
			add(c, "references", "fail", "dangling", { items = table.concat(r.dangling, ", ") })
		else
			add(c, "references", "ok", "references_ok")
		end
		if r.mode == "shunt" then
			add(c, "rules", (r.rules_active or 0) > 0 and "ok" or "info", (r.rules_active or 0) > 0 and "rules_active" or "rules_none",
				{ active = r.rules_active, total = r.rules_total, default = r.default })
		elseif r.mode == "node" then
			add(c, "rules", "info", "rules_not_used")
		end
		if running then
			if r.config_error then
				add(c, "config", "fail", "running_config_unreadable", { detail = r.config_error })
			elseif r.config_rules ~= nil then
				if r.mode == "shunt" and r.rules_active ~= nil and r.config_rules ~= r.rules_active then
					add(c, "config", "warn", "config_differs", { running = r.config_rules, saved = r.rules_active })
				else
					add(c, "config", "ok", "running_config_ok", { rules = r.config_rules, outbounds = r.config_outbounds })
				end
			end
		end
		item("routing", c)
	end

	-- Internet
	c = {}
	local i = p.internet
	if not i then
		unavailable("internet", nil)
	else
		if i.ok then
			add(c, "https", "ok", (running and on(p.localhost_proxy, "1")) and "internet_ok_proxy" or "internet_ok_direct", { http_code = i.http_code, ms = i.ms, url = i.url })
		else
			add(c, "https", "fail", "internet_failed", { http_code = i.http_code, curl_code = i.curl_code, url = i.url,
				through = (running and on(p.localhost_proxy, "1")) and "proxy" or "direct" })
		end
		item("internet", c)
	end

	local all = {}
	for _, it in ipairs(items) do all[#all + 1] = { status = it.status } end
	return { status = M.worst(all), running = running, busy = p.busy and true or false, items = items }
end

return M
