-- Easy VLESS 0.9.0 - Backup / Restore and Import / Export.
--
-- Two different things, two different formats:
--
--   Backup / Restore   the complete state of Easy VLESS, to put the same
--     ("easy-vless-backup")   installation back: the UCI file as it is, the
--                        subscription HWID and the direct IP list. Restore
--                        replaces the whole configuration.
--
--   Import / Export    single kinds of entries to carry to another router or
--     ("easy-vless-export")   to share: servers, rules or subscriptions.
--                        Import only adds entries; it never changes or
--                        removes what is already there, and never touches
--                        settings.
--
-- Everything that comes from a file is untrusted. It is validated completely
-- BEFORE the configuration is changed (check_backup / check_import return
-- what would happen or the reason for the refusal); the caller applies only
-- a positive result, so a bad file leaves the configuration as it was.
--
-- Pure functions (no UCI, no shell; tests/transfer-test.lua). The hash
-- function is passed in by the caller (backup.lua uses sha256sum).

local N = require "luci.easy_vless.nodes"

local M = {}

M.BACKUP_FORMAT = "easy-vless-backup"
M.EXPORT_FORMAT = "easy-vless-export"
M.VERSION = 1
M.MAX_SIZE = 1024 * 1024          -- bytes of a backup / export file
M.MAX_ITEMS = 2000                -- entries of an export file
M.KINDS = { nodes = true, rules = true, subscriptions = true }

local function err(code, extra)
	local e = extra or {}
	e.code = code
	return { ok = false, error = e }
end

-- ---------------------------------------------------------------- UCI text

-- One token of a UCI line: '...', "..." or a bare word. Returns value, rest.
local function token(s)
	s = s:gsub("^%s+", "")
	if s == "" then return nil, "" end
	local out, i = {}, 1
	while i <= #s do
		local c = s:sub(i, i)
		if c == "'" then
			local j = s:find("'", i + 1, true)
			if not j then return nil end
			out[#out + 1] = s:sub(i + 1, j - 1)
			i = j + 1
		elseif c == '"' then
			local j = i + 1
			local buf = {}
			while true do
				local ch = s:sub(j, j)
				if ch == "" then return nil end
				if ch == "\\" then
					buf[#buf + 1] = s:sub(j + 1, j + 1)
					j = j + 2
				elseif ch == '"' then
					break
				else
					buf[#buf + 1] = ch
					j = j + 1
				end
			end
			out[#out + 1] = table.concat(buf)
			i = j + 1
		elseif c:match("%s") then
			break
		elseif c == "\\" then
			out[#out + 1] = s:sub(i + 1, i + 1)
			i = i + 2
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out), s:sub(i)
end

-- A UCI configuration file as a list of sections ({ [".type"], [".name"],
-- option = value, list = { values } }). Returns nil, line number on a line
-- that is not UCI syntax. Values may span lines (quoted line breaks).
function M.parse_uci(text)
	if type(text) ~= "string" then return nil, 0 end
	local sections, cur = {}, nil
	local lines = {}
	for l in (text:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
	local i = 1
	while i <= #lines do
		local line = lines[i]
		local start = i
		-- a quote left open continues on the next line
		local function open_quote(s)
			local q
			local k = 1
			while k <= #s do
				local c = s:sub(k, k)
				if q then
					if c == "\\" and q == '"' then k = k + 1
					elseif c == q then q = nil end
				elseif c == "'" or c == '"' then
					q = c
				elseif c == "\\" then
					k = k + 1
				end
				k = k + 1
			end
			return q ~= nil
		end
		while open_quote(line) and i < #lines do
			i = i + 1
			line = line .. "\n" .. lines[i]
		end
		i = i + 1
		local body = line:gsub("^%s+", "")
		if body ~= "" and body:sub(1, 1) ~= "#" then
			local kw, rest = body:match("^(%a+)%s+(.*)$")
			if not kw then kw = body:match("^(%a+)%s*$") rest = "" end
			if kw == "package" then
				-- "package easy_vless" of "uci export": nothing to keep
			elseif kw == "config" then
				local stype, r2 = token(rest)
				if not stype or not stype:match("^[%w_]+$") then return nil, start end
				local name = token(r2 or "")
				if name and not name:match("^[%w_]+$") then return nil, start end
				cur = { [".type"] = stype, [".name"] = name, [".anonymous"] = name == nil }
				sections[#sections + 1] = cur
			elseif kw == "option" or kw == "list" then
				if not cur then return nil, start end
				local key, r2 = token(rest)
				if not key or not key:match("^[%w_]+$") then return nil, start end
				local value, r3 = token(r2 or "")
				if value == nil then
					if (r2 or ""):match("^%s*$") then value = "" else return nil, start end
				end
				if r3 and not r3:match("^%s*$") then return nil, start end
				if kw == "list" then
					if type(cur[key]) ~= "table" then cur[key] = {} end
					table.insert(cur[key], value)
				else
					cur[key] = value
				end
			else
				return nil, start
			end
		end
	end
	return sections
end

local function count(sections)
	local c = { servers = 0, groups = 0, rules = 0, subscriptions = 0 }
	for _, s in ipairs(sections) do
		if N.is_server(s) then c.servers = c.servers + 1
		elseif s[".type"] == "nodes" and s.protocol == "_urltest" then c.groups = c.groups + 1
		elseif s[".type"] == "shunt_rules" then c.rules = c.rules + 1
		elseif s[".type"] == "subscribe_list" then c.subscriptions = c.subscriptions + 1 end
	end
	return c
end

-- ---------------------------------------------------------------- backup

local function payload(files)
	return (files.config or "") .. "\0" .. (files.hwid or "") .. "\0" .. (files.direct_ip or "")
end

-- files = { config = text of /etc/config/easy_vless, hwid, direct_ip }
function M.make_backup(files, meta, hashfn)
	return {
		format = M.BACKUP_FORMAT,
		version = M.VERSION,
		app_version = meta and meta.app_version or nil,
		created = meta and meta.created or nil,
		hostname = meta and meta.hostname or nil,
		files = { config = files.config, hwid = files.hwid, direct_ip = files.direct_ip },
		sha256 = hashfn(payload(files)),
	}
end

local function valid_direct_ip(text)
	for line in tostring(text):gmatch("[^\r\n]+") do
		local l = line:match("^%s*(.-)%s*$")
		if l ~= "" and l:sub(1, 1) ~= "#" and not l:match("^[%x:%./]+$") and not l:match("^geoip:[%w_%-]+$") then
			return false, l
		end
	end
	return true
end

-- Is this a backup that can be restored? Nothing is changed.
-- Returns { ok = true, summary = { created, app_version, hostname, servers,
-- groups, rules, subscriptions, enabled, node }, warnings = { { code, ... } } }
-- or { ok = false, error = { code, ... } }:
--   not_backup   another kind of file (an export file names itself: kind)
--   version      made by a newer Easy VLESS than this one understands
--   too_large, damaged (hash), config_syntax (line), config_empty,
--   no_global (not an Easy VLESS configuration), hwid, direct_ip (line)
function M.check_backup(doc, hashfn, size)
	if type(doc) ~= "table" then return err("not_json") end
	if size and size > M.MAX_SIZE then return err("too_large", { max = M.MAX_SIZE }) end
	if doc.format ~= M.BACKUP_FORMAT then
		return err("not_backup", { format = type(doc.format) == "string" and doc.format:sub(1, 40) or nil,
			kind = doc.format == M.EXPORT_FORMAT and doc.kind or nil })
	end
	if type(doc.version) ~= "number" or doc.version < 1 then return err("version", { version = doc.version }) end
	if doc.version > M.VERSION then return err("version", { version = doc.version, supported = M.VERSION }) end
	local files = doc.files
	if type(files) ~= "table" or type(files.config) ~= "string" then return err("damaged", { what = "files" }) end
	for _, k in ipairs({ "hwid", "direct_ip" }) do
		if files[k] ~= nil and type(files[k]) ~= "string" then return err("damaged", { what = k }) end
	end
	if #files.config > M.MAX_SIZE then return err("too_large", { max = M.MAX_SIZE }) end
	if type(doc.sha256) ~= "string" or doc.sha256:lower() ~= tostring(hashfn(payload(files))):lower() then
		return err("damaged", { what = "sha256" })
	end
	if files.config:match("^%s*$") then return err("config_empty") end
	local sections, line = M.parse_uci(files.config)
	if not sections then return err("config_syntax", { line = line }) end
	local global
	for _, s in ipairs(sections) do
		if s[".type"] == "global" then global = s end
	end
	if not global then return err("no_global") end
	if files.hwid and files.hwid ~= "" and not (files.hwid:match("^[%w%-]+%s*$") and #files.hwid >= 16 and #files.hwid <= 130) then
		return err("hwid")
	end
	if files.direct_ip then
		local ok, bad = valid_direct_ip(files.direct_ip)
		if not ok then return err("direct_ip", { line = bad:sub(1, 60) }) end
	end
	local res = { ok = true, warnings = {}, summary = count(sections) }
	res.summary.created = type(doc.created) == "number" and doc.created or nil
	res.summary.app_version = type(doc.app_version) == "string" and doc.app_version:sub(1, 40) or nil
	res.summary.hostname = type(doc.hostname) == "string" and doc.hostname:sub(1, 60) or nil
	res.summary.enabled = global.enabled == "1"
	res.summary.node = global.node
	res.summary.hwid = (files.hwid and files.hwid ~= "") and true or false
	local dangling = N.dangling(sections)
	if #dangling > 0 then
		res.warnings[#res.warnings + 1] = { code = "dangling", items = table.concat(dangling, ", ") }
	end
	return res
end

-- ---------------------------------------------------------------- export

local INTERNAL = { [".name"] = true, [".type"] = true, [".anonymous"] = true, [".index"] = true }

-- Options that describe where an entry lives on this router, not the entry.
local DROP = {
	nodes = { add_mode = true, group = true },
	rules = {},
	subscriptions = { md5 = true, update_time = true, excluded_node = true },
}

local function special_target(t)
	return t == "_direct" or t == "_blackhole" or t == "_default"
end

-- Export all entries of one kind. A rule carries its target only when the
-- target means the same everywhere (Direct, Block, Default target): a server
-- of this router is not part of a rule.
function M.export(sections, kind, meta)
	if not M.KINDS[kind] then return nil end
	local router
	for _, s in ipairs(sections) do
		if s[".type"] == "nodes" and s.protocol == "_shunt" then router = router or s end
	end
	local items = {}
	for _, s in ipairs(sections) do
		local take = (kind == "nodes" and N.is_server(s)) or (kind == "rules" and s[".type"] == "shunt_rules")
			or (kind == "subscriptions" and s[".type"] == "subscribe_list")
		if take then
			local item = {}
			for k, v in pairs(s) do
				if not INTERNAL[k] and not DROP[kind][k] then item[k] = v end
			end
			if kind == "rules" and router and special_target(router[s[".name"]]) then
				item.target = router[s[".name"]]
			end
			items[#items + 1] = item
		end
	end
	return { format = M.EXPORT_FORMAT, version = M.VERSION, kind = kind, app_version = meta and meta.app_version or nil,
		created = meta and meta.created or nil, items = items }
end

-- ---------------------------------------------------------------- import

local function set(list)
	local t = {}
	for _, k in ipairs(list) do t[k] = true end
	return t
end

-- Only options the runtime and LuCI know are taken from a file; anything
-- else in an entry is dropped (and counted), never written to UCI.
local ALLOWED = {
	nodes = set({ "remarks", "type", "protocol", "address", "port", "uuid", "encryption", "flow", "transport",
		"tls", "tls_serverName", "tls_allowInsecure", "alpn", "utls", "fingerprint", "ech", "ech_config",
		"reality", "reality_publicKey", "reality_shortId", "reality_spiderX",
		"ws_host", "ws_path", "ws_enableEarlyData", "ws_maxEarlyData", "ws_earlyDataHeaderName",
		"grpc_serviceName", "grpc_mode", "httpupgrade_host", "httpupgrade_path",
		"tcp_guise", "tcp_guise_http_host", "tcp_guise_http_path", "http_host", "http_path",
		"xhttp_host", "xhttp_path", "xhttp_mode", "tcp_fast_open", "domain_strategy" }),
	rules = set({ "remarks", "network", "port", "source", "sourcePort", "protocol", "inbound",
		"domain_list", "ip_list", "domain_resource" }),
	subscriptions = set({ "remark", "url", "user_agent", "hwid", "update_connected", "auto_update", "auto_update_interval",
		"access_mode", "allowInsecure", "boot_update", "filter_keyword_mode", "filter_discard_list", "filter_keep_list" }),
}
local MULTILINE = { domain_list = true, ip_list = true }
local LISTS = { domain_resource = true, filter_discard_list = true, filter_keep_list = true }

local function clean_value(key, v)
	if LISTS[key] then
		if type(v) == "string" then v = { v } end
		if type(v) ~= "table" or #v > 200 then return nil end
		local out = {}
		for _, x in ipairs(v) do
			if type(x) ~= "string" or #x > 256 or x:find("[%c]") then return nil end
			out[#out + 1] = x
		end
		return out
	end
	if type(v) == "number" or type(v) == "boolean" then v = tostring(v) end
	if type(v) ~= "string" then return nil end
	if MULTILINE[key] then
		if #v > 512 * 1024 or v:gsub("[\r\n\t]", ""):find("[%c]") then return nil end
		return v
	end
	if #v > 2048 or v:find("[%c]") then return nil end
	return v
end

local function valid_ports(v)
	for part in (v .. ","):gmatch("([^,]*),") do
		local a, b = part:match("^(%d+):(%d+)$")
		if not a then a = part:match("^(%d+)$") b = a end
		a, b = tonumber(a), tonumber(b)
		if not a or a < 1 or b > 65535 or a > b then return false end
	end
	return true
end

local function words_in(v, allowed)
	for w in tostring(v):gmatch("[^%s,]+") do
		if not allowed[w] then return false end
	end
	return true
end

local DOMAIN_PREFIX = set({ "domain", "full", "regexp", "geosite", "rule-set", "rs" })

-- a geosite / geoip code: letters, digits and - _ . ! @ (util_sing-box.lua)
local function GEO_CODE(code)
	return code:match("^[%w_%-%.!@]+$") ~= nil and not code:find("..", 1, true)
end

local VALIDATE = {}

function VALIDATE.nodes(o)
	if o.protocol ~= "vless" then return "protocol" end
	if type(o.address) ~= "string" or not (o.address:match("^[%w%.%-]+$") or o.address:match("^[%x:]+$")) or #o.address > 253 then return "address" end
	local port = tonumber(o.port)
	if not port or port < 1 or port > 65535 or port ~= math.floor(port) then return "port" end
	if type(o.uuid) ~= "string" or not o.uuid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then return "uuid" end
	if o.transport and not set({ "tcp", "raw", "ws", "grpc", "httpupgrade", "xhttp", "http", "mkcp", "quic" })[o.transport] then return "transport" end
	for _, k in ipairs({ "tls", "reality", "utls", "tls_allowInsecure" }) do
		if o[k] ~= nil and o[k] ~= "0" and o[k] ~= "1" then return k end
	end
	return nil
end

function VALIDATE.rules(o)
	if type(o.remarks) ~= "string" or o.remarks:match("^%s*$") or #o.remarks > 64 then return "remarks" end
	if o.network and o.network ~= "tcp" and o.network ~= "udp" and o.network ~= "tcp,udp" then return "network" end
	if o.port and not valid_ports(o.port) then return "port" end
	if o.sourcePort and not valid_ports(o.sourcePort) then return "sourcePort" end
	if o.protocol and not words_in(o.protocol, set({ "http", "tls", "quic", "bittorrent" })) then return "protocol" end
	if o.inbound and not words_in(o.inbound, set({ "tproxy", "socks" })) then return "inbound" end
	if o.source then
		for w in o.source:gmatch("%S+") do
			if w ~= "geoip:private" and not w:match("^[%x:%.]+/?%d*$") then return "source" end
		end
	end
	if o.domain_list then
		for line in o.domain_list:gmatch("[^\r\n]+") do
			local p = line:match("^%s*([%a%-]+):")
			if p and not DOMAIN_PREFIX[p] and line:sub(1, 1) ~= "#" then return "domain_list" end
			-- a geodata code becomes a file name and a command argument
			local code = line:match("^%s*geosite:(.-)%s*$")
			if code and not GEO_CODE(code) then return "domain_list" end
		end
	end
	if o.ip_list then
		for line in o.ip_list:gmatch("[^\r\n]+") do
			local l = line:match("^%s*(.-)%s*$")
			if l ~= "" and l:sub(1, 1) ~= "#" then
				local code = l:match("^geoip:(.*)$")
				if code then
					if not GEO_CODE(code) then return "ip_list" end
				elseif not (l:match("^[%x:%.]+$") or l:match("^[%x:%.]+/%d+$") or l:match("^rule%-set:%S+$") or l:match("^rs:%S+$")) then
					return "ip_list"
				end
			end
		end
	end
	for _, id in ipairs(o.domain_resource or {}) do
		if not id:match("^[%w_%-]+$") then return "domain_resource" end
	end
	if o.target ~= nil and not special_target(o.target) then return "target" end
	return nil
end

function VALIDATE.subscriptions(o)
	if type(o.remark) ~= "string" or o.remark:match("^%s*$") or #o.remark > 64 then return "remark" end
	if type(o.url) ~= "string" or not o.url:match("^https?://[^%s'\"`\\<>]+$") then return "url" end
	for _, k in ipairs({ "hwid", "update_connected", "auto_update", "allowInsecure", "boot_update" }) do
		if o[k] ~= nil and o[k] ~= "0" and o[k] ~= "1" then return k end
	end
	if o.access_mode and o.access_mode ~= "direct" and o.access_mode ~= "proxy" then return "access_mode" end
	return nil
end

local function item_name(kind, o)
	local n = (kind == "subscriptions") and o.remark or o.remarks
	if type(n) ~= "string" or n == "" then n = (kind == "nodes" and type(o.address) == "string") and o.address or "?" end
	return n:gsub("[%c]", " "):sub(1, 64)
end

-- What an import would do. Nothing is changed.
--   doc       the decoded file
--   sections  the current configuration (to skip what is already there)
--   want      the kind the user chose (nil = whatever the file contains)
-- Returns { ok = true, kind, add = { { options } ... }, skipped = { { name,
-- reason, field } }, dropped = n } - reason: "exists" (already there),
-- "duplicate" (twice in the file), "invalid" (field names the bad option) -
-- or { ok = false, error = { code } }: not_json, not_export (a backup file
-- names itself), version, kind, kind_mismatch, too_large, items, empty.
-- An entry with an invalid value is skipped as a whole; valid entries of the
-- same file are still offered.
function M.check_import(doc, sections, want, size)
	if type(doc) ~= "table" then return err("not_json") end
	if size and size > M.MAX_SIZE then return err("too_large", { max = M.MAX_SIZE }) end
	if doc.format ~= M.EXPORT_FORMAT then
		return err("not_export", { backup = doc.format == M.BACKUP_FORMAT or nil,
			format = type(doc.format) == "string" and doc.format:sub(1, 40) or nil })
	end
	if type(doc.version) ~= "number" or doc.version < 1 then return err("version", { version = doc.version }) end
	if doc.version > M.VERSION then return err("version", { version = doc.version, supported = M.VERSION }) end
	local kind = doc.kind
	if type(kind) ~= "string" or not M.KINDS[kind] then return err("kind") end
	if want and want ~= "" and want ~= kind then return err("kind_mismatch", { kind = kind, want = want }) end
	if type(doc.items) ~= "table" then return err("items") end
	if #doc.items > M.MAX_ITEMS then return err("too_large", { max = M.MAX_ITEMS }) end
	if #doc.items == 0 then return err("empty") end

	-- what is already there
	local have = {}
	for _, s in ipairs(sections or {}) do
		if kind == "nodes" and N.is_server(s) then have[N.key(s)] = true
		elseif kind == "rules" and s[".type"] == "shunt_rules" then have[s.remarks or ""] = true
		elseif kind == "subscriptions" and s[".type"] == "subscribe_list" then
			have["r:" .. (s.remark or ""):lower()] = true
			have["u:" .. (s.url or "")] = true
		end
	end

	local res = { ok = true, kind = kind, add = {}, skipped = {}, dropped = 0 }
	for _, raw in ipairs(doc.items) do
		if type(raw) ~= "table" then
			res.skipped[#res.skipped + 1] = { name = "?", reason = "invalid", field = "entry" }
		else
			local o, bad = {}, nil
			for k, v in pairs(raw) do
				if type(k) ~= "string" then
					bad = "entry"
				elseif ALLOWED[kind][k] or (kind == "rules" and k == "target") then
					local c = clean_value(k, v)
					if c == nil then bad = bad or k else o[k] = c end
				else
					res.dropped = res.dropped + 1
				end
			end
			bad = bad or VALIDATE[kind](o)
			local name = item_name(kind, o)
			if bad then
				res.skipped[#res.skipped + 1] = { name = name, reason = "invalid", field = bad }
			else
				local keys
				if kind == "nodes" then
					keys = { N.key(o) }
				elseif kind == "rules" then
					keys = { o.remarks }
				else
					keys = { "r:" .. o.remark:lower(), "u:" .. o.url }
				end
				local seen
				for _, k in ipairs(keys) do
					if have[k] then seen = have[k] end
				end
				if seen then
					res.skipped[#res.skipped + 1] = { name = name, reason = (seen == "file") and "duplicate" or "exists" }
				else
					for _, k in ipairs(keys) do have[k] = "file" end
					if kind == "nodes" then
						o.type = (o.type == "Xray") and "Xray" or "sing-box"
						o.add_mode = "1"
					end
					res.add[#res.add + 1] = o
				end
			end
		end
	end
	return res
end

return M
