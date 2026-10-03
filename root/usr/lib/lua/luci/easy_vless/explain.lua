-- Easy VLESS 0.9.0 - Route Explain: where does a connection go, and why.
--
-- This is not a second routing engine. It evaluates the route and DNS rules
-- of the sing-box configuration that util_sing-box.lua generated (the file
-- sing-box really runs, or the one "app.sh check" generates from the saved
-- settings), in the order and with the matching semantics of sing-box 1.12:
--   a rule matches when every condition group it has matches;
--   destination group (any one item): domain, domain_suffix, domain_keyword,
--     domain_regex, ip_cidr, ip_is_private, rule_set
--   port group: port, port_range;  source group: source_ip_cidr,
--     source_ip_is_private;  source port group: source_port, source_port_range
--   single conditions: network, protocol (sniffed), inbound; invert
--   the first matching rule with a final action (route, reject) wins, else
--   route.final.
-- The answer is three-valued. What cannot be computed from the input is
-- reported as "unknown" with the reason, never guessed: a geodata rule-set
-- (binary .srs), a regular expression outside the supported subset, an IP
-- condition for a domain whose address is not known, a source condition
-- without a source address.
--
-- Pure functions over decoded JSON (config, meta file) and plain tables: no
-- UCI, no shell - tests/explain-test.lua runs them with a stock Lua 5.1.
-- The command line wrapper is /usr/share/easy_vless/diag.lua.

local M = {}

local YES, NO, UNKNOWN = "yes", "no", "unknown"
M.YES, M.NO, M.UNKNOWN = YES, NO, UNKNOWN

-- ---------------------------------------------------------------- addresses

local function parse_ipv4(s)
	local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return nil end
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
	return { 0, 0, 0, 0, 0, 0xffff, a * 256 + b, c * 256 + d, v4 = true }
end

local function parse_ipv6(s)
	if not s:find(":", 1, true) or s:find("[^%x:%.]") then return nil end
	local head, tail = s, nil
	local p = s:find("::", 1, true)
	if p then
		if s:find("::", p + 1, true) then return nil end
		head, tail = s:sub(1, p - 1), s:sub(p + 2)
	end
	local function groups(part)
		local t = {}
		if part == "" then return t end
		for g in (part .. ":"):gmatch("([^:]*):") do
			if g:find(".", 1, true) then
				local v4 = parse_ipv4(g)
				if not v4 then return nil end
				t[#t + 1] = v4[7]
				t[#t + 1] = v4[8]
			else
				if #g == 0 or #g > 4 then return nil end
				t[#t + 1] = tonumber(g, 16)
			end
		end
		return t
	end
	local h, t = groups(head), tail and groups(tail) or {}
	if not h or not t then return nil end
	if tail == nil then
		if #h ~= 8 then return nil end
		return h
	end
	if #h + #t > 7 then return nil end
	local out = {}
	for i = 1, #h do out[i] = h[i] end
	for i = #h + 1, 8 - #t do out[i] = 0 end
	for i = 1, #t do out[8 - #t + i] = t[i] end
	return out
end

-- An address as 8 groups of 16 bit (IPv4 as ::ffff:a.b.c.d, flag v4).
function M.parse_ip(s)
	if type(s) ~= "string" then return nil end
	return parse_ipv4(s) or parse_ipv6(s)
end

function M.in_cidr(ip, cidr)
	local addr, bits = cidr:match("^(.-)/(%d+)$")
	addr = addr or cidr
	local net = M.parse_ip(addr)
	if not net or (net.v4 and true or false) ~= (ip.v4 and true or false) then return false end
	bits = tonumber(bits) or (net.v4 and 32 or 128)
	if net.v4 then
		if bits > 32 then return false end
		bits = bits + 96
	elseif bits > 128 then
		return false
	end
	for i = 1, 8 do
		if bits <= 0 then return true end
		local n = math.min(bits, 16)
		local div = 2 ^ (16 - n)
		if math.floor(ip[i] / div) ~= math.floor(net[i] / div) then return false end
		bits = bits - n
	end
	return true
end

local PRIVATE4 = { "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4", "0.0.0.0/32" }
local PRIVATE6 = { "fc00::/7", "::1/128", "fe80::/10", "ff00::/8", "::/128" }

-- sing-box ip_is_private: not a public address
function M.is_private(ip)
	for _, c in ipairs(ip.v4 and PRIVATE4 or PRIVATE6) do
		if M.in_cidr(ip, c) then return true end
	end
	return false
end

M.FAKE_IP4, M.FAKE_IP6 = "198.18.0.0/16", "fc00::/18"

function M.is_fake_ip(ip)
	return M.in_cidr(ip, ip.v4 and M.FAKE_IP4 or M.FAKE_IP6)
end

-- ---------------------------------------------------------------- input

local SCHEME_PORT = { http = 80, https = 443, ws = 80, wss = 443 }

-- What the user typed: a domain, an IP, host:port, [ipv6]:port or a URL.
-- Returns { kind = "domain" | "ip", host, ip, port } or nil, error code.
function M.parse_input(text)
	if type(text) ~= "string" then return nil, "empty" end
	local s = text:match("^%s*(.-)%s*$")
	if s == "" then return nil, "empty" end
	if #s > 300 then return nil, "invalid" end
	local q = {}
	local scheme, rest = s:match("^(%a[%w+.-]*)://(.*)$")
	if scheme then
		q.port = SCHEME_PORT[scheme:lower()]
		s = rest
	end
	s = s:gsub("[/?#].*$", ""):gsub("^[^@]*@", "")
	local host, port = s:match("^%[(.-)%]:(%d+)$")
	if not host then host = s:match("^%[(.-)%]$") end
	if not host then
		if M.parse_ip(s) then
			host = s
		else
			host, port = s:match("^(.-):(%d+)$")
			if not host then host = s end
		end
	end
	if port then
		port = tonumber(port)
		if port < 1 or port > 65535 then return nil, "port" end
		q.port = port
	end
	if M.parse_ip(host) then
		q.kind, q.ip = "ip", host:lower()
		return q
	end
	host = host:lower():gsub("%.$", "")
	if host == "" or #host > 253 or host:find("[^%w%.%-_]") or host:find("%.%.", 1) or host:sub(1, 1) == "." or host:match("^[%d%.]+$") then
		return nil, "invalid"
	end
	q.kind, q.host = "domain", host
	return q
end

-- The protocol sing-box would most likely sniff, when the user did not say:
-- TCP 443 TLS, TCP 80 HTTP, UDP 443 QUIC. Anything else: not known.
function M.guess_protocol(network, port)
	if network == "tcp" and port == 443 then return "tls" end
	if network == "tcp" and port == 80 then return "http" end
	if network == "udp" and port == 443 then return "quic" end
	return nil
end

-- ---------------------------------------------------------------- regular expressions

-- A small backtracking matcher for the RE2 subset used in domain lists:
-- literals, ., [classes], \d \w \s (and upper case), ^ $, groups with |,
-- * + ? {m,n}. Anything else (flags other than a leading (?i), \b, \p{..},
-- ...) is not supported: compile returns nil and the caller reports the
-- expression as "unknown". Matching is a search, like Go's MatchString.
local RE_STEPS = 200000

local function class_escape(c)
	if c == "d" then return function(ch) return ch:match("%d") ~= nil end end
	if c == "w" then return function(ch) return ch:match("[%w_]") ~= nil end end
	if c == "s" then return function(ch) return ch:match("%s") ~= nil end end
	if c == "D" then return function(ch) return ch:match("%d") == nil end end
	if c == "W" then return function(ch) return ch:match("[%w_]") == nil end end
	if c == "S" then return function(ch) return ch:match("%s") == nil end end
	return nil
end

local function re_parse(p)
	local pos = 1
	local parse_alt

	local function parse_class()
		-- after "["
		local negate = false
		if p:sub(pos, pos) == "^" then negate = true pos = pos + 1 end
		local tests = {}
		local first = true
		while true do
			local c = p:sub(pos, pos)
			if c == "" then return nil end
			if c == "]" and not first then pos = pos + 1 break end
			first = false
			if c == "[" and p:sub(pos + 1, pos + 1) == ":" then return nil end
			local lo
			if c == "\\" then
				local e = p:sub(pos + 1, pos + 1)
				if e == "" then return nil end
				pos = pos + 2
				local f = class_escape(e)
				if f then
					tests[#tests + 1] = f
				elseif e:match("%w") then
					return nil
				else
					lo = e
				end
			else
				lo = c
				pos = pos + 1
			end
			if lo then
				if p:sub(pos, pos) == "-" and p:sub(pos + 1, pos + 1) ~= "]" and p:sub(pos + 1, pos + 1) ~= "" then
					local hi = p:sub(pos + 1, pos + 1)
					if hi == "\\" then
						hi = p:sub(pos + 2, pos + 2)
						pos = pos + 1
					end
					pos = pos + 2
					local a, b = lo:byte(), hi:byte()
					tests[#tests + 1] = function(ch) local x = ch:byte() return x >= a and x <= b end
				else
					tests[#tests + 1] = function(ch) return ch == lo end
				end
			end
		end
		return { t = "set", f = function(ch)
			for i = 1, #tests do
				if tests[i](ch) then return not negate end
			end
			return negate
		end }
	end

	local function parse_atom()
		local c = p:sub(pos, pos)
		if c == "(" then
			pos = pos + 1
			if p:sub(pos, pos) == "?" then
				if p:sub(pos, pos + 1) == "?:" then
					pos = pos + 2
				else
					local n = p:match("^%?P?<[%w_]+>()", pos)
					if not n then return nil end
					pos = n
				end
			end
			local inner = parse_alt()
			if not inner or p:sub(pos, pos) ~= ")" then return nil end
			pos = pos + 1
			return { t = "group", n = inner }
		elseif c == "[" then
			pos = pos + 1
			return parse_class()
		elseif c == "." then
			pos = pos + 1
			return { t = "set", f = function(ch) return ch ~= "\n" end }
		elseif c == "^" then
			pos = pos + 1
			return { t = "bol" }
		elseif c == "$" then
			pos = pos + 1
			return { t = "eol" }
		elseif c == "\\" then
			local e = p:sub(pos + 1, pos + 1)
			if e == "" then return nil end
			pos = pos + 2
			local f = class_escape(e)
			if f then return { t = "set", f = f } end
			if e:match("%w") then return nil end
			return { t = "set", f = function(ch) return ch == e end }
		elseif c == "*" or c == "+" or c == "?" or c == "{" or c == ")" or c == "|" or c == "" then
			return nil
		end
		pos = pos + 1
		return { t = "set", f = function(ch) return ch == c end }
	end

	local function parse_seq()
		local items = {}
		while pos <= #p do
			local c = p:sub(pos, pos)
			if c == "|" or c == ")" then break end
			local atom = parse_atom()
			if not atom then return nil end
			local q = p:sub(pos, pos)
			local min, max
			if q == "*" then min, max = 0, math.huge pos = pos + 1
			elseif q == "+" then min, max = 1, math.huge pos = pos + 1
			elseif q == "?" then min, max = 0, 1 pos = pos + 1
			elseif q == "{" then
				local a, b, e = p:match("^{(%d+),?(%d*)}()", pos)
				if not a then return nil end
				min = tonumber(a)
				if p:sub(pos, e - 1):find(",", 1, true) then
					max = (b ~= "") and tonumber(b) or math.huge
				else
					max = min
				end
				if max < min or min > 1000 then return nil end
				pos = e
			end
			if min then
				if atom.t == "bol" or atom.t == "eol" then return nil end
				if p:sub(pos, pos) == "?" then pos = pos + 1 end   -- lazy: same answer for "does it match"
				if p:sub(pos, pos):match("[*+{]") then return nil end
				atom = { t = "rep", n = atom, min = min, max = max }
			end
			items[#items + 1] = atom
		end
		return { t = "seq", items = items }
	end

	parse_alt = function()
		local alts = {}
		while true do
			local s = parse_seq()
			if not s then return nil end
			alts[#alts + 1] = s
			if p:sub(pos, pos) == "|" then pos = pos + 1 else break end
		end
		return { t = "alt", alts = alts }
	end

	local ast = parse_alt()
	if not ast or pos <= #p then return nil end
	return ast
end

-- compile(pattern) -> function(s) -> true | false | nil (too expensive), or
-- nil when the pattern is outside the supported subset.
function M.re_compile(pattern)
	local icase = false
	if pattern:sub(1, 4) == "(?i)" then
		icase = true
		pattern = pattern:sub(5)
	end
	if pattern:find("(?", 1, true) and pattern:find("%(%?[^:P<]") then return nil end
	local ok, ast = pcall(re_parse, icase and pattern:lower() or pattern)
	if not ok or not ast then return nil end

	return function(s)
		if icase then s = s:lower() end
		local steps = 0
		local m
		local function match_seq(items, idx, i, k)
			if idx > #items then return k(i) end
			return m(items[idx], i, function(j) return match_seq(items, idx + 1, j, k) end)
		end
		m = function(node, i, k)
			steps = steps + 1
			if steps > RE_STEPS then error("steps") end
			local t = node.t
			if t == "set" then
				if i <= #s and node.f(s:sub(i, i)) then return k(i + 1) end
				return false
			elseif t == "bol" then
				return i == 1 and k(i)
			elseif t == "eol" then
				return i == #s + 1 and k(i)
			elseif t == "seq" then
				return match_seq(node.items, 1, i, k)
			elseif t == "alt" then
				for _, a in ipairs(node.alts) do
					if m(a, i, k) then return true end
				end
				return false
			elseif t == "group" then
				return m(node.n, i, k)
			elseif t == "rep" then
				local function try(count, j)
					if count < node.max then
						if m(node.n, j, function(j2)
							if j2 == j then return false end   -- no progress: stop repeating
							return try(count + 1, j2)
						end) then return true end
					end
					return count >= node.min and k(j)
				end
				return try(0, i)
			end
			return false
		end
		local ok2, res = pcall(function()
			for start = 1, #s + 1 do
				if m(ast, start, function() return true end) then return true end
			end
			return false
		end)
		if not ok2 then return nil end
		return res
	end
end

-- ---------------------------------------------------------------- conditions

local function list(v)
	if v == nil then return {} end
	if type(v) ~= "table" then return { v } end
	return v
end

local function has(v)
	return v ~= nil and (type(v) ~= "table" or #v > 0)
end

-- domain_suffix as sing-box matches it: the domain itself and its
-- subdomains (label boundary); with a leading dot: subdomains only.
local function suffix_match(host, suffix)
	suffix = suffix:lower()
	if suffix:sub(1, 1) == "." then
		return #host > #suffix and host:sub(-#suffix) == suffix
	end
	return host == suffix or (#host > #suffix and host:sub(-#suffix - 1) == "." .. suffix)
end

local function port_in(port, ports, ranges)
	for _, p in ipairs(list(ports)) do
		if tonumber(p) == port then return true end
	end
	for _, r in ipairs(list(ranges)) do
		local a, b = tostring(r):match("^(%d*):(%d*)$")
		if a then
			a, b = tonumber(a) or 0, tonumber(b) or 65535
			if port >= a and port <= b then return true end
		end
	end
	return false
end

-- One OR-group: items is a list of { result, why }. yes if any is yes,
-- else unknown if any is unknown, else no.
local function any_of(results)
	local unknown
	for _, r in ipairs(results) do
		if r[1] == YES then return YES, r[2] end
		if r[1] == UNKNOWN and not unknown then unknown = r[2] end
	end
	if unknown then return UNKNOWN, unknown end
	return NO, results[1] and results[1][2]
end

-- Destination group of a route or DNS rule. Returns nil when the rule has no
-- destination condition, else result and why { code, item }.
local function match_destination(rule, q, ctx, dns)
	local has_domain = has(rule.domain) or has(rule.domain_suffix) or has(rule.domain_keyword) or has(rule.domain_regex)
	local has_ip = not dns and (has(rule.ip_cidr) or rule.ip_is_private)
	local has_set = has(rule.rule_set)
	if not has_domain and not has_ip and not has_set then return nil end

	local res = {}
	if has_domain then
		if not q.host then
			res[#res + 1] = { NO, { code = "no_domain" } }
		else
			local host = q.host
			for _, d in ipairs(list(rule.domain)) do
				if host == tostring(d):lower() then res[#res + 1] = { YES, { code = "domain", item = d } } break end
			end
			for _, d in ipairs(list(rule.domain_suffix)) do
				if suffix_match(host, tostring(d)) then res[#res + 1] = { YES, { code = "domain_suffix", item = d } } break end
			end
			for _, d in ipairs(list(rule.domain_keyword)) do
				if host:find(tostring(d):lower(), 1, true) then res[#res + 1] = { YES, { code = "domain_keyword", item = d } } break end
			end
			for _, d in ipairs(list(rule.domain_regex)) do
				local re = ctx.regex[d]
				if re == nil then
					re = M.re_compile(d) or false
					ctx.regex[d] = re
				end
				local r = re and re(host)
				if r == true then
					res[#res + 1] = { YES, { code = "domain_regex", item = d } }
					break
				elseif r == nil or re == false then
					res[#res + 1] = { UNKNOWN, { code = "regex_unsupported", item = d } }
				end
			end
			if #res == 0 then res[1] = { NO, { code = "domain_no_match" } } end
		end
	end
	if has_ip then
		local ips = q.ips or {}
		if #ips == 0 then
			res[#res + 1] = { UNKNOWN, { code = "ip_unknown" } }
		else
			local hit
			for _, ip in ipairs(ips) do
				local parsed = M.parse_ip(ip)
				if parsed then
					if rule.ip_is_private and M.is_private(parsed) then
						hit = { code = "ip_is_private", item = ip }
					end
					for _, c in ipairs(list(rule.ip_cidr)) do
						if not hit and M.in_cidr(parsed, tostring(c)) then
							hit = { code = "ip_cidr", item = c, ip = ip }
						end
					end
				end
				if hit then break end
			end
			res[#res + 1] = hit and { YES, hit } or { NO, { code = "ip_no_match" } }
		end
	end
	if has_set then
		-- generated sets are geodata converted to binary .srs: not readable here
		res[#res + 1] = { UNKNOWN, { code = "rule_set", item = table.concat(list(rule.rule_set), ", ") } }
	end
	return any_of(res)
end

-- Evaluate one route rule. Returns result (yes / no / unknown), reasons:
-- for "yes" the conditions that matched, for "no" the first group that did
-- not, for "unknown" what could not be computed.
function M.match_rule(rule, q, ctx)
	ctx = ctx or { regex = {} }
	local matched, unknown = {}, {}
	local failed

	local function group(result, why)
		if result == nil then return end
		if result == YES then
			if why then matched[#matched + 1] = why end
		elseif result == NO then
			failed = failed or why or { code = "no_match" }
		else
			unknown[#unknown + 1] = why
		end
	end

	if has(rule.inbound) then
		local ok = false
		for _, t in ipairs(list(rule.inbound)) do
			if t == q.inbound then ok = true end
		end
		group(ok and YES or NO, { code = "inbound", item = table.concat(list(rule.inbound), ", "), value = q.inbound })
	end
	if has(rule.network) then
		local ok = false
		for _, n in ipairs(list(rule.network)) do
			if n == q.network then ok = true end
		end
		-- "tcp,udp" is every connection: not worth a reason
		group(ok and YES or NO, (#list(rule.network) < 2) and { code = "network", item = table.concat(list(rule.network), ", "), value = q.network } or nil)
	end
	if has(rule.protocol) then
		local item = table.concat(list(rule.protocol), ", ")
		if not q.protocol then
			group(UNKNOWN, { code = "protocol_unknown", item = item })
		else
			local ok = false
			for _, p in ipairs(list(rule.protocol)) do
				if p == q.protocol then ok = true end
			end
			group(ok and YES or NO, { code = "protocol", item = item, value = q.protocol })
		end
	end
	if has(rule.port) or has(rule.port_range) then
		local item = table.concat(list(rule.port), ",")
		if has(rule.port_range) then item = item .. (item ~= "" and "," or "") .. table.concat(list(rule.port_range), ",") end
		if not q.port then
			group(UNKNOWN, { code = "port_unknown", item = item })
		else
			group(port_in(q.port, rule.port, rule.port_range) and YES or NO, { code = "port", item = item, value = q.port })
		end
	end
	if has(rule.source_ip_cidr) or rule.source_ip_is_private then
		local src = q.source and M.parse_ip(q.source)
		if not src then
			group(UNKNOWN, { code = "source_unknown" })
		else
			local hit
			if rule.source_ip_is_private and M.is_private(src) then hit = "private" end
			for _, c in ipairs(list(rule.source_ip_cidr)) do
				if not hit and M.in_cidr(src, tostring(c)) then hit = c end
			end
			group(hit and YES or NO, { code = "source", item = hit, value = q.source })
		end
	end
	if has(rule.source_port) or has(rule.source_port_range) then
		if not q.source_port then
			group(UNKNOWN, { code = "source_port_unknown" })
		else
			group(port_in(q.source_port, rule.source_port, rule.source_port_range) and YES or NO, { code = "source_port", value = q.source_port })
		end
	end
	group(match_destination(rule, q, ctx, false))

	local result
	if failed then result = NO
	elseif #unknown > 0 then result = UNKNOWN
	else result = YES end
	if rule.invert then
		if result == YES then result = NO failed = { code = "invert" }
		elseif result == NO then result = YES matched = { { code = "invert" } } end
	end
	if result == YES then return YES, matched end
	if result == NO then return NO, { failed } end
	return UNKNOWN, unknown
end

-- ---------------------------------------------------------------- route

local function action_of(rule)
	return rule.action or "route"
end

local function final_action(rule)
	local a = action_of(rule)
	return a == "route" or a == "reject" or a == "hijack-dns"
end

-- The transparent inbound a connection of this network arrives on.
function M.inbound_for(config, network)
	local tags = {}
	for _, i in ipairs(config.inbounds or {}) do tags[i.tag or ""] = i end
	if network == "tcp" and tags["redirect_tcp"] then return "redirect_tcp" end
	if network == "udp" and tags["tproxy_udp"] then return "tproxy_udp" end
	if tags["tproxy"] then return "tproxy" end
	return nil
end

-- What an outbound tag stands for: { kind = direct | block | server | group
-- | unknown, tag, id (node id), members = { { tag, id } } }.
function M.describe_outbound(config, meta, tag)
	if tag == nil then return { kind = "unknown" } end
	if tag == "direct" then return { kind = "direct", tag = tag } end
	if tag == "block" then return { kind = "block", tag = tag } end
	local ob
	for _, o in ipairs(config.outbounds or {}) do
		if o.tag == tag then ob = o break end
	end
	if not ob then return { kind = "unknown", tag = tag } end
	local ids = (meta and meta.outbounds) or {}
	if ob.type == "urltest" or ob.type == "selector" then
		local members = {}
		for _, t in ipairs(ob.outbounds or {}) do
			members[#members + 1] = { tag = t, id = ids[t] }
		end
		return { kind = "group", tag = tag, id = tag:match("^urltest%-(.+)$"), members = members, url = ob.url }
	end
	if ob.type == "direct" then return { kind = "direct", tag = tag, interface = ob.bind_interface } end
	if ob.type == "block" then return { kind = "block", tag = tag } end
	return { kind = "server", tag = tag, id = ids[tag], type = ob.type, detour = (ob.detour and ob.detour ~= "direct") and ob.detour or nil }
end

-- Names of the generated shunt rules: route rule index -> { id, priority }.
local function rule_names(meta)
	local t = {}
	for n, r in ipairs((meta and meta.rules) or {}) do
		t[r.index] = { id = r.id, priority = n }
	end
	return t
end

-- Where a connection goes.
--   q = { host, ips = { ... }, port, network, protocol, source, source_port,
--         inbound }
-- Returns {
--   certain   false when a rule before the match could not be evaluated
--   match     { kind = "rule" | "default", index, rule_id, priority, action,
--               reasons, target }
--   possible  rules before the match that may apply (unknown), same shape
--             plus reasons = what is unknown
--   skipped   named rules before the match that do not apply:
--             { rule_id, priority, why }
-- }
function M.route(config, meta, q)
	local ctx = { regex = {} }
	local names = rule_names(meta)
	local res = { certain = true, possible = {}, skipped = {} }
	local rules = (config.route and config.route.rules) or {}
	for i, rule in ipairs(rules) do
		if final_action(rule) then
			local r, why = M.match_rule(rule, q, ctx)
			local name = names[i]
			local entry = { kind = "rule", index = i, rule_id = name and name.id, priority = name and name.priority,
				action = action_of(rule), reasons = why }
			if action_of(rule) == "reject" then
				entry.target = { kind = "block" }
			elseif action_of(rule) == "route" then
				entry.target = M.describe_outbound(config, meta, rule.outbound)
			end
			if r == YES then
				res.match = entry
				break
			elseif r == UNKNOWN then
				res.certain = false
				res.possible[#res.possible + 1] = entry
			elseif name then
				res.skipped[#res.skipped + 1] = { rule_id = name.id, priority = name.priority, why = why[1] }
			end
		end
	end
	if not res.match then
		local final = config.route and config.route.final
		if not final then
			-- sing-box: without route.final the first outbound is used
			final = config.outbounds and config.outbounds[1] and config.outbounds[1].tag
		end
		res.match = { kind = "default", action = "route", reasons = {}, target = M.describe_outbound(config, meta, final) }
	end
	return res
end

-- ---------------------------------------------------------------- DNS

local function dns_server(config, tag)
	for _, s in ipairs((config.dns and config.dns.servers) or {}) do
		if s.tag == tag then return s end
	end
end

-- What a DNS server of the configuration is, for the user:
--   kind    direct | remote | fakeip | local | hosts | other
--   detour  how the queries to it travel: describe_outbound of its detour
function M.describe_dns_server(config, meta, tag)
	local s = dns_server(config, tag)
	if not s then return { kind = "unknown", tag = tag } end
	local d = { tag = tag, type = s.type, address = s.server, port = s.server_port, path = s.path }
	if s.type == "fakeip" then
		d.kind = "fakeip"
		d.range4, d.range6 = s.inet4_range, s.inet6_range
	elseif s.type == "local" then
		d.kind = "local"
	elseif s.type == "hosts" then
		d.kind = "hosts"
	else
		-- a server without a detour is dialled directly
		local via = s.detour
		d.detour = (via == nil or via == "direct") and { kind = "direct" } or M.describe_outbound(config, meta, via)
		if tag == "direct" then
			d.kind = "direct"
		elseif tag == "remote" or d.detour.kind ~= "direct" then
			d.kind = "remote"
		else
			d.kind = "other"
		end
	end
	return d
end

-- Which DNS rule answers a query for host (qtype "A" or "AAAA").
-- Returns { certain, match = { kind = "rule" | "final", index, action =
-- "route" | "predefined", server = describe_dns_server, client_subnet,
-- reasons }, possible = { ... } }.
function M.dns(config, meta, host, qtype)
	local ctx = { regex = {} }
	local res = { certain = true, possible = {}, qtype = qtype }
	local dns = config.dns or {}
	local q = { host = host }
	for i, rule in ipairs(dns.rules or {}) do
		local result, why = YES, {}
		if has(rule.query_type) then
			local ok = false
			for _, t in ipairs(list(rule.query_type)) do
				if tostring(t):upper() == qtype then ok = true end
			end
			if not ok then result = NO end
		end
		if result ~= NO and has(rule.inbound) then
			result = NO   -- rules bound to another inbound do not see LAN queries
			for _, t in ipairs(list(rule.inbound)) do
				if t == "dns-in" then result = YES end
			end
		end
		if result ~= NO then
			local r, w = match_destination(rule, q, ctx, true)
			if r ~= nil then
				result = r
				why = { w }
			end
			if rule.invert then
				if result == YES then result = NO elseif result == NO then result = YES why = { { code = "invert" } } end
			end
		end
		local entry = { kind = "rule", index = i, action = rule.action or "route", reasons = why,
			client_subnet = rule.client_subnet, rcode = rule.rcode }
		if entry.action == "route" then
			entry.server = M.describe_dns_server(config, meta, rule.server)
		end
		if result == YES then
			res.match = entry
			break
		elseif result == UNKNOWN then
			res.certain = false
			res.possible[#res.possible + 1] = entry
		end
	end
	if not res.match then
		local final = dns.final or (dns.servers and dns.servers[1] and dns.servers[1].tag)
		res.match = { kind = "final", action = "route", reasons = {}, server = M.describe_dns_server(config, meta, final) }
	end
	return res
end

-- ---------------------------------------------------------------- interception

local function ports_cover(spec, port)
	if spec == nil or spec == "" then return true end
	spec = tostring(spec)
	if spec == "disable" then return false end
	for part in spec:gmatch("[^,%s]+") do
		local a, b = part:match("^(%d+)[:%-](%d+)$")
		if a then
			if port >= tonumber(a) and port <= tonumber(b) then return true end
		elseif tonumber(part) == port then
			return true
		end
	end
	return false
end
M.ports_cover = ports_cover

-- Does the firewall hand this connection to sing-box at all? The route rules
-- only see what nftables redirects (nftables.sh):
--   settings = { tcp_proxy_way, tcp_redir_ports, udp_redir_ports,
--                tcp_no_redir_ports, udp_no_redir_ports, ipv6_tproxy,
--                client_proxy, localhost_proxy }
--   q = { network, port, ips, fake } (fake: the client gets a FakeDNS address)
-- Returns { intercepted = yes | no | unknown, method = "tproxy" | "redirect",
-- reasons = { { code, ... } }, lan, router }.
function M.interception(settings, q)
	local way = (settings.tcp_proxy_way == "redirect") and "redirect" or "tproxy"
	local res = { method = (q.network == "udp") and "tproxy" or way, reasons = {},
		lan = settings.client_proxy ~= "0", router = settings.localhost_proxy ~= "0" }
	local function no(code, extra)
		res.intercepted = NO
		extra = extra or {}
		extra.code = code
		res.reasons[#res.reasons + 1] = extra
		return res
	end
	if not res.lan and not res.router then
		return no("proxy_off")
	end
	local proto = (q.network == "udp") and "udp" or "tcp"
	local no_ports = settings[proto .. "_no_redir_ports"]
	if q.port and no_ports and no_ports ~= "" and no_ports ~= "disable" and ports_cover(no_ports, q.port) then
		return no("no_redir_port", { ports = no_ports, port = q.port })
	end
	if q.fake then
		-- the FakeDNS range is redirected on every port
		res.intercepted = YES
		res.reasons[1] = { code = "fake_ip" }
		return res
	end
	local ips = q.ips or {}
	local v6_only = #ips > 0
	for _, ip in ipairs(ips) do
		local p = M.parse_ip(ip)
		if p and p.v4 then v6_only = false end
		if p and M.is_private(p) then
			return no("private_ip", { ip = ip })
		end
	end
	if v6_only and settings.ipv6_tproxy ~= "1" then
		return no("ipv6_off")
	end
	local redir = settings[proto .. "_redir_ports"]
	if redir == nil or redir == "" then redir = "1:65535" end
	if q.port then
		if not ports_cover(redir, q.port) then
			return no("port_not_redirected", { ports = redir, port = q.port })
		end
		res.intercepted = YES
	else
		res.intercepted = (redir == "1:65535") and YES or UNKNOWN
		if res.intercepted == UNKNOWN then res.reasons[1] = { code = "port_unknown", ports = redir } end
	end
	return res
end

return M
