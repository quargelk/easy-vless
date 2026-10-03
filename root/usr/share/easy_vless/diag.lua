#!/usr/bin/lua
-- Easy VLESS 0.9.0 - Route Explain and diagnostics for LuCI (rpcd "diag").
-- Prints one JSON object on stdout.
--
--   lua diag.lua explain '<json>'   { input, network, port, protocol, source }
--   lua diag.lua dns <domain>
--   lua diag.lua forwarding
--   lua diag.lua connection
--
-- This file only collects the state of the router; what it means is decided
-- by the modules it shares with the unit tests:
--   luci/easy_vless/explain.lua    route / DNS rules of the sing-box config
--   luci/easy_vless/diagnose.lua   forwarding, DNS, the connection panel
--   luci/easy_vless/nodes.lua      references of the saved configuration
--
-- Concurrency: everything here is read-only. It never starts sing-box, never
-- takes the operation lock itself and never waits for it. The one thing that
-- needs the lock - a consistent copy of the sing-box configuration (the
-- running one, or the one generated from the saved settings while stopped) -
-- is done by "app.sh diag_config" under the lock with a short wait; while a
-- start or stop holds it, the answer is "busy" instead of a queued operation
-- or a half-written file. app.sh stop() does not kill this process.

local api = require "luci.easy_vless.api"
local X = require "luci.easy_vless.explain"
local D = require "luci.easy_vless.diagnose"
local N = require "luci.easy_vless.nodes"
local jsonc = api.jsonc
local fs = api.fs
local nixio = api.nixio

local CONFIG = api.c_config
local APP = "/usr/share/" .. CONFIG .. "/app.sh"
local TMP_PATH = "/tmp/etc/" .. CONFIG
local TEST_DIR = "/var/run/" .. CONFIG .. "_test"
local PROBE_URL = "https://www.gstatic.com/generate_204"
local PROBE_DOMAIN = "www.gstatic.com"
local LOOKUP_TIMEOUT = 2

local function q(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function sh(cmd)
	local p = io.popen(cmd .. " 2>&1")
	if not p then return "" end
	local out = p:read("*a") or ""
	p:close()
	return out
end

local function now_ms()
	local s, us = nixio.gettimeofday()
	return s * 1000 + math.floor(us / 1000)
end

local function trim(s)
	return (tostring(s or ""):match("^%s*(.-)%s*$"))
end

local function readfile(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local c = f:read("*a")
	f:close()
	return c
end

local function cache_var(key)
	local text = readfile(TMP_PATH .. "/var") or ""
	local val
	for k, v in text:gmatch('([%w_%-]+)="([^"\n]*)"') do
		if k == key then val = v end
	end
	return val
end

local function get(section, option, default)
	local v = api.uci_get_c(section, option)
	if v == nil or v == "" then return default end
	return v
end

local function status()
	return jsonc.parse(sh(APP .. " status")) or {}
end

-- A start or stop is in progress (init script lock): the state is in flux.
local function busy()
	return fs.access("/var/lock/" .. CONFIG .. ".lock") and true or false
end

local function settings()
	local s = {}
	for _, k in ipairs({ "tcp_proxy_way", "tcp_redir_ports", "udp_redir_ports", "tcp_no_redir_ports", "udp_no_redir_ports", "ipv6_tproxy" }) do
		s[k] = get("@global_forwarding[0]", k)
	end
	for _, k in ipairs({ "client_proxy", "localhost_proxy", "dns_redirect", "remote_fakedns", "remote_dns_query_strategy",
		"direct_dns_query_strategy", "remote_dns_client_ip", "remote_dns_protocol", "remote_dns_detour", "node", "enabled" }) do
		s[k] = get("@global[0]", k)
	end
	s.tcp_proxy_way = s.tcp_proxy_way or "tproxy"
	return s
end

local function sections()
	local t = {}
	for _, stype in ipairs({ "global", "nodes", "shunt_rules", "subscribe_list" }) do
		api.uci_foreach_c(stype, function(s) t[#t + 1] = s end)
	end
	return t
end

local function node_name(id)
	if not id then return nil end
	return get(id, "remarks")
end

-- ---------------------------------------------------------------- sing-box configuration

-- A private copy of the configuration (see the header). Returns config,
-- meta, kind ("running" | "saved"), or nil, nil, nil, error text / "busy".
local function load_config()
	local dir = trim(sh("mktemp -d /tmp/" .. CONFIG .. "_diag.XXXXXX"))
	if dir == "" or not dir:match("^/tmp/" .. CONFIG .. "_diag%.[%w]+$") then
		return nil, nil, nil, "cannot create a temporary directory"
	end
	local out = trim(sh(APP .. " diag_config " .. q(dir)))
	local kind = out:match("([^\n]*)$")
	local cfg, meta
	if kind == "running" or kind == "saved" then
		cfg = jsonc.parse(readfile(dir .. "/config.json") or "")
		meta = jsonc.parse(readfile(dir .. "/config.json.meta") or "") or {}
	end
	sh("rm -rf " .. q(dir))
	if out == "busy" then return nil, nil, nil, "busy" end
	if type(cfg) ~= "table" then
		return nil, nil, nil, (out:gsub("^error:", "")):sub(1, 600)
	end
	return cfg, meta, kind
end

-- ---------------------------------------------------------------- lookups

-- One DNS query with nslookup; server / port nil = the router's resolver.
local function lookup(host, qtype, server, port)
	local opts = string.format("-type=%s -timeout=%d -retry=1", qtype:lower(), LOOKUP_TIMEOUT)
	if port then opts = opts .. " -port=" .. tonumber(port) end
	local tail = q(host) .. (server and (" " .. q(server)) or "")
	local t0 = now_ms()
	local out = sh("nslookup " .. opts .. " " .. tail)
	if out:find("Usage:", 1, true) or out:lower():find("unrecognized option", 1, true) or out:lower():find("invalid option", 1, true) then
		-- a small nslookup without options: only the default query is possible
		if port then
			return { status = "error", addresses = {}, detail = "this nslookup cannot query another port" }
		end
		t0 = now_ms()
		out = sh("nslookup " .. tail)
	end
	local res = D.parse_nslookup(out)
	res.ms = now_ms() - t0
	return res
end

-- ---------------------------------------------------------------- names for the user

local function name_target(t)
	if type(t) ~= "table" then return t end
	if t.kind == "server" then
		t.name = node_name(t.id)
	elseif t.kind == "group" then
		t.name = node_name(t.id)
		for _, m in ipairs(t.members or {}) do
			m.name = node_name(m.id)
		end
	end
	return t
end

-- The server a running URL Test group uses right now (Clash API).
local function group_now(t)
	if t.kind ~= "group" or not t.id then return end
	local clash = "/usr/share/" .. CONFIG .. "/clash_api.lua"
	if not fs.access(clash) then return end
	local res = jsonc.parse(sh("lua " .. clash .. " groups")) or {}
	for _, g in ipairs(res.groups or {}) do
		if g.id == t.id then
			for _, m in ipairs(g.members or {}) do
				if m.tag == g.now then
					t.now = { id = m.id, name = node_name(m.id) or m.tag, delay = m.delay }
				end
			end
		end
	end
end

-- Where the matched domain entry of a rule comes from: one of the rule's
-- prepared resources, or its manual domain list.
local PREFIX = { domain_suffix = "domain:", domain = "full:", domain_regex = "regexp:", domain_keyword = "" }
local function origin(rule_id, reason)
	if not rule_id or not reason or PREFIX[reason.code] == nil or not reason.item then return nil end
	local rule = api.uci_get_c(rule_id)
	if type(rule) ~= "table" then return nil end
	local want = PREFIX[reason.code] .. tostring(reason.item)
	local function has(text)
		for line in tostring(text or ""):gmatch("[^\r\n]+") do
			if trim(line) == want then return true end
		end
		return false
	end
	for _, id in ipairs(api.rule_resource_ids(rule)) do
		local r = api.get_resource(id)
		if r and r.file and has(readfile(r.file)) then
			return { kind = "resource", id = id, name = r.name or id }
		end
	end
	if has(rule.domain_list) then return { kind = "manual" } end
	return nil
end

local function name_entry(e)
	if not e then return end
	if e.rule_id then e.rule_name = get(e.rule_id, "remarks", e.rule_id) end
	name_target(e.target)
	if e.reasons then
		for _, r in ipairs(e.reasons) do
			local o = origin(e.rule_id, r)
			if o then r.origin = o end
		end
	end
end

local function name_dns(d)
	if not d then return end
	for _, e in ipairs({ d.match, unpack(d.possible or {}) }) do
		if e.server and e.server.detour then name_target(e.server.detour) end
	end
end

-- ---------------------------------------------------------------- explain

local PROTOCOLS = { tls = true, http = true, quic = true, bittorrent = true }

local function cmd_explain(raw)
	local a = jsonc.parse(raw or "") or {}
	local inp, err = X.parse_input(a.input)
	if not inp then
		return { ok = false, error = "input", reason = err }
	end
	local network = (a.network == "udp") and "udp" or "tcp"
	local port = tonumber(a.port) or inp.port
	local port_assumed = false
	if port and (port < 1 or port > 65535) then
		return { ok = false, error = "input", reason = "port" }
	end
	if not port then
		port, port_assumed = 443, true
	end
	local protocol = PROTOCOLS[a.protocol or ""] and a.protocol or nil
	local protocol_assumed = false
	if not protocol and a.protocol ~= "none" then
		protocol = X.guess_protocol(network, port)
		protocol_assumed = protocol ~= nil
	end
	local source = (type(a.source) == "string" and X.parse_ip(trim(a.source))) and trim(a.source) or nil
	if a.source and trim(a.source) ~= "" and not source then
		return { ok = false, error = "input", reason = "source" }
	end

	local cfg, meta, kind, cerr = load_config()
	if not cfg then
		return { ok = false, error = (cerr == "busy") and "busy" or "config", detail = cerr }
	end

	local res = { ok = true,
		input = { text = trim(a.input), kind = inp.kind, host = inp.host, ip = inp.ip, port = port, port_assumed = port_assumed,
			network = network, protocol = protocol, protocol_assumed = protocol_assumed, source = source },
		config = { source = kind, node = meta.node } }

	local ips, fake = nil, false
	if inp.kind == "ip" then
		ips = { inp.ip }
		fake = X.is_fake_ip(X.parse_ip(inp.ip))
	else
		res.dns = { a = X.dns(cfg, meta, inp.host, "A"), aaaa = X.dns(cfg, meta, inp.host, "AAAA") }
		name_dns(res.dns.a)
		name_dns(res.dns.aaaa)
		local m = res.dns.a.match
		if m.server and m.server.kind == "fakeip" and res.dns.a.certain then
			-- the device connects to a FakeDNS address; sing-box takes the name from it
			fake = true
			ips = { "198.18.0.1" }
		end
	end

	local query = { host = inp.host, ips = ips, port = port, network = network, protocol = protocol, source = source,
		inbound = X.inbound_for(cfg, network) }
	local route = X.route(cfg, meta, query)

	-- a rule depends on the address the name resolves to: ask the router's DNS
	local function needs_ip(r)
		for _, e in ipairs(r.possible) do
			for _, why in ipairs(e.reasons or {}) do
				if why.code == "ip_unknown" then return true end
			end
		end
		return false
	end
	if inp.kind == "domain" and not ips and needs_ip(route) then
		local l = lookup(inp.host, "a")
		res.resolved = { status = l.status, addresses = l.addresses, ms = l.ms }
		if l.status == "ok" and #l.addresses > 0 then
			query.ips = l.addresses
			route = X.route(cfg, meta, query)
		end
	end

	name_entry(route.match)
	for _, e in ipairs(route.possible) do name_entry(e) end
	for _, e in ipairs(route.skipped) do
		e.rule_name = get(e.rule_id, "remarks", e.rule_id)
	end
	if route.match.target and kind == "running" then group_now(route.match.target) end
	res.route = route
	res.fake_ip = fake
	res.inbound = query.inbound
	res.intercept = X.interception(settings(), { network = network, port = port, ips = (not fake) and query.ips or nil, fake = fake })
	return res
end

-- ---------------------------------------------------------------- forwarding

local function forwarding_state(st, s)
	local state = { running = st.running and true or false, settings = s }
	state.fw4 = trim(sh("command -v fw4")) ~= ""
	if trim(sh("command -v nft")) == "" then
		state.fw4 = false
	else
		local out = sh("nft list table inet " .. CONFIG)
		-- the listing itself, not nft's error message (which repeats the command)
		if out:find("^%s*table inet " .. CONFIG .. " {") then
			state.nft = out
		elseif not out:lower():find("no such file", 1, true) and not out:lower():find("does not exist", 1, true) and trim(out) ~= "" then
			state.nft_error = trim(out):sub(1, 200)
		end
	end
	state.rule4 = sh("ip rule show")
	state.route4 = sh("ip route show table " .. D.ROUTE_TABLE)
	if s.ipv6_tproxy == "1" then
		state.rule6 = sh("ip -6 rule show")
		state.route6 = sh("ip -6 route show table " .. D.ROUTE_TABLE)
	end
	if s.node then
		state.redir_port = tonumber(cache_var("node_" .. s.node .. "_redir_port"))
	end
	return state
end

local function cmd_forwarding()
	local st, s = status(), settings()
	local res = D.forwarding(forwarding_state(st, s))
	res.ok = true
	res.busy = busy()
	return res
end

-- ---------------------------------------------------------------- DNS

local function dns_result(domain, st, s, with_aaaa)
	local running = st.running and true or false
	local state = { running = running, domain = domain, settings = s, lookup = {} }
	state.lookup.a = lookup(domain, "a")
	if with_aaaa then state.lookup.aaaa = lookup(domain, "aaaa") end
	if not running then
		return D.dns(state)
	end

	local nft = sh("nft list chain inet " .. CONFIG .. " EV_DNS")
	state.forwarding = { dns_redirect = nft:find("redirect to", 1, true) ~= nil }
	local conf = cache_var("DEFAULT_DNSMASQ_CONF")
	state.dnsmasq = { forwards_to_singbox = (conf and fs.access(conf)) and true or false }

	local cfg, meta, kind, cerr = load_config()
	if cfg and kind == "running" then
		state.plan = { a = X.dns(cfg, meta, domain, "A"), aaaa = X.dns(cfg, meta, domain, "AAAA") }
		name_dns(state.plan.a)
		name_dns(state.plan.aaaa)
		state.probe = {}
		-- Direct DNS: asked directly (the firewall lets the router reach it)
		for _, srv in ipairs((cfg.dns and cfg.dns.servers) or {}) do
			if srv.tag == "direct" and srv.server then
				local p = lookup(domain, "a", srv.server, srv.server_port or 53)
				p.server = srv.server .. ":" .. tostring(srv.server_port or 53)
				state.probe.direct = p
			end
		end
		-- Remote DNS: through sing-box, with a query type its rules send to
		-- the remote server for this domain (FakeDNS answers A/AAAA itself)
		local dns_port
		for _, i in ipairs(cfg.inbounds or {}) do
			if i.tag == "dns-in" then dns_port = i.listen_port end
		end
		local probe_type
		for _, t in ipairs({ "A", "TXT" }) do
			local plan = X.dns(cfg, meta, domain, t)
			if plan.certain and plan.match.action == "route" and plan.match.server and plan.match.server.kind == "remote" then
				probe_type = t
				state.probe.remote = { server = (plan.match.server.address or "?") .. ":" .. tostring(plan.match.server.port or ""),
					via = plan.match.server.detour and (name_target(plan.match.server.detour).name or plan.match.server.detour.kind) }
				break
			end
		end
		if probe_type and dns_port then
			local p = lookup(domain, probe_type, "127.0.0.1", dns_port)
			p.server, p.via = state.probe.remote.server, state.probe.remote.via
			state.probe.remote = p
		else
			state.probe.remote = { skipped = dns_port and "not_used_for_domain" or "no_dns_inbound" }
		end
	end
	local res = D.dns(state)
	if not cfg then res.config_error = cerr end
	res.plan = state.plan
	return res
end

local function cmd_dns(domain)
	local inp, err = X.parse_input(domain)
	if not inp or inp.kind ~= "domain" then
		return { ok = false, error = "input", reason = inp and "not_domain" or err }
	end
	local res = dns_result(inp.host, status(), settings(), true)
	res.ok = true
	res.domain = inp.host
	res.busy = busy()
	return res
end

-- ---------------------------------------------------------------- connection

-- The selected VLESS node (the same notion as LuCI's ev.selectedNode).
local function selected_node(all)
	local byname, global, rules = {}, nil, {}
	for _, sec in ipairs(all) do
		byname[sec[".name"]] = sec
		if sec[".type"] == "global" then global = sec end
		if sec[".type"] == "shunt_rules" then rules[#rules + 1] = sec[".name"] end
	end
	local function proxy(id)
		local n = id and byname[id]
		return n and n[".type"] == "nodes" and (N.is_server(n) or n.protocol == "_urltest")
	end
	local node = global and global.node
	if not node or node == "" then return { kind = "none" } end
	local main = byname[node]
	if not main or main[".type"] ~= "nodes" then return { kind = "missing", id = node } end
	local id = node
	if main.protocol == "_shunt" then
		id = nil
		if proxy(main.default_node) then
			id = main.default_node
		else
			for _, r in ipairs(rules) do
				if proxy(main[r]) then id = main[r] break end
			end
		end
		if not id then return { kind = "direct" } end
	end
	local n = byname[id]
	if n.protocol == "_urltest" then
		local members = type(n.urltest_node) == "table" and #n.urltest_node or (n.urltest_node and 1 or 0)
		return { kind = "group", id = id, name = n.remarks, members = members }
	end
	local res = { kind = "server", id = id, name = n.remarks }
	local last = jsonc.parse(readfile(TEST_DIR .. "/r/" .. id .. ".server.json") or "")
	-- a result made for another address (the server was edited) does not count
	if type(last) == "table" and last.address == n.address and tostring(last.port) == tostring(n.port) then
		res.test = { ok = last.ok and true or false, delay = last.delay, error_kind = last.error_kind, error = last.error,
			age = last.time and (os.time() - tonumber(last.time)) or nil }
	end
	return res
end

local function routing_state(all, st)
	local r = { dangling = N.dangling(all) }
	local main, total, active = nil, 0, 0
	for _, sec in ipairs(all) do
		if sec[".type"] == "global" and sec.node then
			for _, n in ipairs(all) do
				if n[".name"] == sec.node then main = n end
			end
		end
	end
	if main and main.protocol == "_shunt" then
		r.mode = "shunt"
		for _, sec in ipairs(all) do
			if sec[".type"] == "shunt_rules" then
				total = total + 1
				if sec.remarks and main[sec[".name"]] and main[sec[".name"]] ~= "" then active = active + 1 end
			end
		end
		r.rules_total, r.rules_active = total, active
		r.default = main.default_node or "_direct"
	elseif main then
		r.mode = "node"
	end
	if st.running then
		local path = cache_var("easy_vless_main_config")
		local meta = path and jsonc.parse(readfile(path .. ".meta") or "")
		if type(meta) == "table" then
			r.config_rules = #(meta.rules or {})
			local n = 0
			for _ in pairs(meta.outbounds or {}) do n = n + 1 end
			r.config_outbounds = n
		elseif not path or not fs.access(path) then
			r.config_error = "the configuration file of the running sing-box was not found"
		end
	end
	return r
end

local function internet()
	local t0 = now_ms()
	local out = trim(sh("curl -s -o /dev/null --connect-timeout 4 --max-time 8 -w '%{http_code} %{exitcode}' " .. q(PROBE_URL)))
	local code, exit = out:match("^(%d+)%s+(%d+)$")
	if not code then code = out:match("^(%d+)") end
	return { ok = (code == "204" or code == "200"), http_code = code, curl_code = tonumber(exit), ms = now_ms() - t0, url = PROBE_URL }
end

local function cmd_connection()
	local st, s = status(), settings()
	local all = sections()
	local parts = { status = st, busy = busy(), localhost_proxy = s.localhost_proxy or "1" }

	local env = trim(sh(APP .. " env_check"))
	if env == "ok" then
		parts.env = { ok = true }
	else
		local kind, detail = env:match("^(%a+):(.*)$")
		parts.env = { ok = false, kind = kind or "env", detail = (detail or env):sub(1, 400) }
	end

	local ok, res = pcall(function() return D.forwarding(forwarding_state(st, s)) end)
	parts.forwarding = ok and res or { unavailable = tostring(res) }
	ok, res = pcall(dns_result, PROBE_DOMAIN, st, s, false)
	parts.dns = ok and res or { unavailable = tostring(res) }
	if ok then parts.dns.plan = nil end
	ok, res = pcall(selected_node, all)
	parts.node = ok and res or nil
	ok, res = pcall(routing_state, all, st)
	parts.routing = ok and res or nil
	ok, res = pcall(internet)
	parts.internet = ok and res or nil

	local out = D.connection(parts)
	out.ok = true
	out.probe_domain = PROBE_DOMAIN
	return out
end

-- ---------------------------------------------------------------- main

local commands = {
	explain = function() return cmd_explain(arg[2]) end,
	dns = function() return cmd_dns(arg[2]) end,
	forwarding = cmd_forwarding,
	connection = cmd_connection,
}

local fn = commands[arg[1] or ""]
local result
if not fn then
	result = { ok = false, error = "action" }
else
	local ok, res = pcall(fn)
	if ok then
		result = res
	else
		result = { ok = false, error = "internal", detail = tostring(res):sub(1, 400) }
	end
end
io.write(jsonc.stringify(result) .. "\n")
