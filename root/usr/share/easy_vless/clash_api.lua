#!/usr/bin/lua
-- Easy VLESS: minimal client for the Clash API of the running sing-box
-- instance (experimental.clash_api, see util_sing-box.lua / app.sh).
-- Shipped by easy-vless-sing-box. Prints JSON on stdout.
--
--   lua clash_api.lua groups                 URL Test groups with members and last delays
--   lua clash_api.lua test <group_id> [url]  run the group's URL test now, then print groups
--
-- Group tags are "urltest-<uci section>", members "ut-<uci section>:<remarks>"
-- (util_sing-box.lua gen_urltest_outbound), so results map back to UCI ids.

local jsonc = require "luci.jsonc"

local STATE_FILE = "/tmp/etc/easy_vless/clash_api"
local DEFAULT_URL = "https://x.com" -- same default as util_sing-box.lua gen_urltest_outbound

local function out(t)
	print(jsonc.stringify(t))
end

local function fail(msg)
	out({ ok = false, error = msg })
	os.exit(0)
end

local function read_state()
	local f = io.open(STATE_FILE, "r")
	if not f then return nil end
	local line = f:read("*l") or ""
	f:close()
	return line:match("^(%d+)%s+(%x+)$")
end

local function urlencode(s)
	return (tostring(s):gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", c:byte())
	end))
end

local function shellquote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function request(path, timeout)
	local port, secret = read_state()
	if not port then
		return nil, "Easy VLESS is not running (no Clash API endpoint)."
	end
	local cmd = string.format("curl -s -m %d -H %s %s 2>/dev/null",
		timeout or 10,
		shellquote("Authorization: Bearer " .. secret),
		shellquote("http://127.0.0.1:" .. port .. path))
	local p = io.popen(cmd)
	local body = p and p:read("*a") or ""
	if p then p:close() end
	local data = jsonc.parse(body)
	if type(data) ~= "table" then
		return nil, "No valid response from the sing-box Clash API on 127.0.0.1:" .. port .. "."
	end
	return data
end

local function last_delay(proxy)
	local h = proxy and proxy.history
	if type(h) == "table" and #h > 0 then
		local d = tonumber(h[#h].delay)
		return d, h[#h].time
	end
	return nil
end

local function groups()
	local data, err = request("/proxies", 10)
	if not data then return nil, err end
	local proxies = data.proxies or {}
	local result = {}
	for tag, p in pairs(proxies) do
		if p.type == "URLTest" then
			local g = {
				tag = tag,
				id = tag:match("^urltest%-(.+)$"),
				now = p.now,
				now_id = p.now and p.now:match("^ut%-([^:]+)") or nil,
				members = {}
			}
			for _, m in ipairs(p.all or {}) do
				local d, t = last_delay(proxies[m])
				g.members[#g.members + 1] = {
					tag = m,
					id = m:match("^ut%-([^:]+)"),
					delay = d,   -- ms; 0 = last test failed; nil = not tested yet
					time = t
				}
			end
			result[#result + 1] = g
		end
	end
	table.sort(result, function(a, b) return a.tag < b.tag end)
	return result
end

local cmd = arg[1]
if cmd == "groups" then
	local g, err = groups()
	if not g then fail(err) end
	out({ ok = true, groups = g })
elseif cmd == "test" then
	-- Force a fresh test of every member through the running instance:
	-- GET /proxies/<member>/delay stores the result in sing-box's URL test
	-- history (the same history the urltest group uses for its selection).
	-- /group/<tag>/delay is not used because sing-box skips members tested
	-- within the group interval there.
	local id = arg[2]
	if not id or id == "" then fail("Missing URL Test group id.") end
	local url = (arg[3] and arg[3] ~= "") and arg[3] or DEFAULT_URL
	local g, err = groups()
	if not g then fail(err) end
	local group
	for _, v in ipairs(g) do
		if v.id == id then group = v end
	end
	if not group then
		fail("URL Test group " .. id .. " is not part of the running configuration (make it active or use it in a rule, then start Easy VLESS).")
	end
	local port, secret = read_state()
	local dir = os.tmpname()
	os.remove(dir)
	os.execute("mkdir -p " .. shellquote(dir))
	-- At most BATCH requests at a time (1.0): one curl process per member of
	-- a large group - a subscription with a hundred servers - is more than a
	-- small router has memory for. A batch takes 8 s at most; batches are
	-- started only within the time one rpcd request may take.
	local BATCH, BUDGET = 16, 20
	local t0 = os.time()
	local started = 0
	while started < #group.members and (started == 0 or os.time() - t0 < BUDGET) do
		local cmds = {}
		for i = started + 1, math.min(started + BATCH, #group.members) do
			local m = group.members[i]
			cmds[#cmds + 1] = string.format("curl -s -m 8 -H %s %s > %s 2>/dev/null &",
				shellquote("Authorization: Bearer " .. secret),
				shellquote("http://127.0.0.1:" .. port .. "/proxies/" .. urlencode(m.tag) .. "/delay?timeout=5000&url=" .. urlencode(url)),
				shellquote(dir .. "/" .. i))
		end
		started = started + #cmds
		os.execute(table.concat(cmds, "\n") .. "\nwait")
	end
	local tested = {}
	for i, m in ipairs(group.members) do
		if i > started then
			tested[#tested + 1] = { id = m.id, tag = m.tag, skipped = true,
				error = "Not tested in this run: the group is large. Run the test again." }
		else
			local f = io.open(dir .. "/" .. i, "r")
			local r = f and jsonc.parse(f:read("*a") or "") or nil
			if f then f:close() end
			tested[#tested + 1] = { id = m.id, tag = m.tag, delay = r and tonumber(r.delay) or 0, error = r and r.message or nil }
		end
	end
	os.execute("rm -rf " .. shellquote(dir))
	local g2, err2 = groups()
	if not g2 then fail(err2) end
	out({ ok = true, tested = tested, groups = g2 })
else
	fail("usage: clash_api.lua groups | test <group_id> [url]")
end
