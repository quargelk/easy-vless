-- Easy VLESS - Backup / Restore and Import / Export (0.9.0): unit /
-- regression test of root/usr/lib/lua/luci/easy_vless/transfer.lua with a
-- stock Lua 5.1.
--
--   lua5.1 tests/transfer-test.lua      (static checks, CI "checks" job)
--
-- Covered: the UCI text parser, a backup is accepted only when it is intact
-- and really an Easy VLESS configuration, the two formats are not confused,
-- import validation (every refused file and entry has a reason; hostile
-- values never become UCI options), duplicates, what export leaves out.

package.path = "root/usr/lib/lua/?.lua;" .. package.path
local T = require "luci.easy_vless.transfer"

local pass, fail = 0, 0
local function check(msg, cond)
	if cond then pass = pass + 1 print("PASS: " .. msg)
	else fail = fail + 1 print("FAIL: " .. msg) end
end
-- stand-in for sha256sum: any deterministic function of the content
local function hash(s)
	local h = 7
	for i = 1, #s do h = (h * 31 + s:byte(i)) % 4294967296 end
	return string.format("%08x%08x", h, #s)
end

local UUID = "00000000-0000-4000-8000-000000000001"
local CONFIG = table.concat({
	"",
	"config global 'global'",
	"\toption enabled '1'",
	"\toption node 'main_router'",
	"\toption remote_dns '1.1.1.1'",
	"",
	"config nodes 'srv1'",
	"\toption remarks 'Finland #1'",
	"\toption type 'sing-box'",
	"\toption protocol 'vless'",
	"\toption address 'fi.example.net'",
	"\toption port '443'",
	"\toption uuid '" .. UUID .. "'",
	"\toption add_mode '2'",
	"\toption group 'Provider'",
	"",
	"config nodes 'main_router'",
	"\toption remarks 'Main Router'",
	"\toption protocol '_shunt'",
	"\toption default_node 'srv1'",
	"\toption PROXY 'srv1'",
	"\toption RUSSIA '_direct'",
	"",
	"config shunt_rules 'RUSSIA'",
	"\toption remarks 'RUSSIA'",
	"\toption network 'tcp,udp'",
	"\tlist domain_resource 'russia'",
	"",
	"config shunt_rules 'PROXY'",
	"\toption remarks 'PROXY'",
	"\toption network 'tcp,udp'",
	"\tlist domain_resource 'proxy'",
	"\toption domain_list 'domain:example.org",
	"full:www.example.com'",
	"",
	"config subscribe_list",
	"\toption remark 'Provider'",
	"\toption url 'https://sub.example.net/list?token=abc'",
	"\toption md5 'd41d8cd98f00b204e9800998ecf8427e'",
	"\tlist excluded_node '0123456789abcdef Germany'",
	"",
}, "\n")

-- ---------------------------------------------------------------- UCI text
local sections, line = T.parse_uci(CONFIG)
local function by(name)
	for _, s in ipairs(sections) do
		if s[".name"] == name then return s end
	end
end
check("uci: sections parsed", sections and #sections == 6 and by("global")[".type"] == "global")
check("uci: options and names", by("srv1").remarks == "Finland #1" and by("srv1").port == "443" and by("main_router").default_node == "srv1")
check("uci: lists", type(by("RUSSIA").domain_resource) == "table" and by("RUSSIA").domain_resource[1] == "russia")
check("uci: a value spanning lines", by("PROXY").domain_list == "domain:example.org\nfull:www.example.com")
check("uci: anonymous section", sections[6][".type"] == "subscribe_list" and sections[6][".name"] == nil and sections[6].url == "https://sub.example.net/list?token=abc")
local q = T.parse_uci("config nodes 'a'\n\toption remarks 'it'\\''s \"x\"'\n\toption b \"dq \\\" v\"\n\toption c bare\n")
check("uci: escaped quotes, double quotes, bare words", q and q[1].remarks == "it's \"x\"" and q[1].b == 'dq " v' and q[1].c == "bare")
check("uci: 'package' line and comments are accepted", T.parse_uci("package easy_vless\n\n# comment\nconfig global 'global'\n\toption enabled '0'\n") ~= nil)
sections, line = T.parse_uci("config global 'global'\n\toption enabled '1'\nthis is not uci\n")
check("uci: a line that is not UCI is reported with its number", sections == nil and line == 3)
check("uci: option before any section", T.parse_uci("\toption a 'b'\n") == nil)
check("uci: unterminated quote", T.parse_uci("config global 'global'\n\toption a 'b\n") == nil)
check("uci: bad section or option name", T.parse_uci("config glo;bal 'x'\n") == nil and T.parse_uci("config global 'g'\n\toption a-b 'c'\n") == nil)
check("uci: not text", T.parse_uci(nil) == nil)
sections = T.parse_uci(CONFIG)

-- ---------------------------------------------------------------- backup
local files = { config = CONFIG, hwid = "0123456789abcdef0123456789abcdef", direct_ip = "# local\n10.0.0.0/8\ngeoip:private\nfd00::/8\n" }
local backup = T.make_backup(files, { app_version = "0.9.0-r1", created = 1790000000, hostname = "OpenWrt" }, hash)
check("backup: format, version, hash", backup.format == "easy-vless-backup" and backup.version == 1 and #backup.sha256 > 8 and backup.files.config == CONFIG)
local r = T.check_backup(backup, hash)
check("check: an intact backup is accepted", r.ok == true)
check("check: summary of what it contains", r.summary.servers == 1 and r.summary.rules == 2 and r.summary.subscriptions == 1 and r.summary.groups == 0
	and r.summary.enabled == true and r.summary.node == "main_router" and r.summary.app_version == "0.9.0-r1" and r.summary.created == 1790000000 and r.summary.hwid == true)
check("check: no warning for a consistent configuration", #r.warnings == 0)

local function broken(change)
	local b = T.make_backup(files, {}, hash)
	change(b)
	local res = T.check_backup(b, hash)
	return res.ok == false and res.error.code or "accepted"
end
check("check: changed content (hash mismatch) -> damaged", broken(function(b) b.files.config = b.files.config .. "\nconfig nodes 'evil'\n" end) == "damaged")
check("check: changed HWID -> damaged", broken(function(b) b.files.hwid = "ffffffffffffffffffffffff" end) == "damaged")
check("check: missing hash -> damaged", broken(function(b) b.sha256 = nil end) == "damaged")
check("check: missing files -> damaged", broken(function(b) b.files = nil end) == "damaged" and broken(function(b) b.files.config = nil end) == "damaged")
check("check: newer format version is refused", broken(function(b) b.version = 2 end) == "version")
check("check: not a backup", broken(function(b) b.format = "something" end) == "not_backup" and T.check_backup("text", hash).error.code == "not_json")
local function rebuilt(f)
	local res = T.check_backup(T.make_backup(f, {}, hash), hash)
	return res.ok and "accepted" or res.error.code, res
end
check("check: configuration with a syntax error, with the line", rebuilt({ config = "config global 'global'\nbroken line\n" }) == "config_syntax"
	and select(2, rebuilt({ config = "config global 'global'\nbroken line\n" })).error.line == 2)
check("check: empty configuration", rebuilt({ config = "  \n" }) == "config_empty")
check("check: a UCI file that is not an Easy VLESS configuration", rebuilt({ config = "config interface 'lan'\n\toption proto 'static'\n" }) == "no_global")
check("check: HWID with other characters", rebuilt({ config = CONFIG, hwid = "abc; rm -rf /" }) == "hwid")
check("check: direct IP list with something that is not an address", rebuilt({ config = CONFIG, direct_ip = "10.0.0.0/8\n$(reboot)\n" }) == "direct_ip")
check("check: too large", T.check_backup(backup, hash, T.MAX_SIZE + 1).error.code == "too_large")
check("check: backup without HWID and direct IP list is fine", rebuilt({ config = CONFIG }) == "accepted")
local _, res = rebuilt({ config = CONFIG:gsub("option default_node 'srv1'", "option default_node 'gone'") })
check("check: a target that points to a missing node is a warning, not a refusal", res.ok and res.warnings[1].code == "dangling" and res.warnings[1].items == "main_router.default_node")

-- the two formats are not confused
local exp = T.export(sections, "nodes", { app_version = "0.9.0-r1", created = 1790000000 })
r = T.check_backup(exp, hash)
check("restore of an export file: refused, and named as an export of servers", r.ok == false and r.error.code == "not_backup" and r.error.kind == "nodes")
r = T.check_import(backup, sections)
check("import of a backup file: refused, and named as a backup", r.ok == false and r.error.code == "not_export" and r.error.backup == true)

-- ---------------------------------------------------------------- export
check("export nodes: servers only, without router-local options", exp.format == "easy-vless-export" and exp.kind == "nodes" and #exp.items == 1
	and exp.items[1].address == "fi.example.net" and exp.items[1].add_mode == nil and exp.items[1].group == nil and exp.items[1][".name"] == nil)
local er = T.export(sections, "rules")
check("export rules: conditions; a special target is kept, a server target is not", #er.items == 2 and er.items[1].remarks == "RUSSIA" and er.items[1].target == "_direct"
	and er.items[2].remarks == "PROXY" and er.items[2].target == nil and er.items[2].domain_list == "domain:example.org\nfull:www.example.com")
local es = T.export(sections, "subscriptions")
check("export subscriptions: without update state and deleted nodes", #es.items == 1 and es.items[1].url == "https://sub.example.net/list?token=abc" and es.items[1].md5 == nil and es.items[1].excluded_node == nil)
check("export: unknown kind", T.export(sections, "settings") == nil)

-- ---------------------------------------------------------------- import
local function doc(kind, items, o)
	local d = { format = "easy-vless-export", version = 1, kind = kind, items = items }
	for k, v in pairs(o or {}) do d[k] = v end
	return d
end
local function node(o)
	local n = { remarks = "DE", protocol = "vless", address = "de.example.net", port = "443", uuid = UUID, transport = "tcp", tls = "1" }
	for k, v in pairs(o or {}) do n[k] = v end
	return n
end
local function code(d, want) local x = T.check_import(d, sections, want) return x.ok and "ok" or x.error.code end
local function skip(x) return x.skipped[1] and (x.skipped[1].reason .. ":" .. tostring(x.skipped[1].field)) or "none" end

r = T.check_import(doc("nodes", { node() }), sections)
check("import: a new server is offered", r.ok and #r.add == 1 and #r.skipped == 0 and r.add[1].address == "de.example.net")
check("import: marked as imported (never as a subscription node), backend defaulted", r.add[1].add_mode == "1" and r.add[1].type == "sing-box" and r.add[1].group == nil)
r = T.check_import(exp, sections)
check("import: a server that already exists is skipped ('exists'), nothing to add", r.ok and #r.add == 0 and skip(r) == "exists:nil" and r.skipped[1].name == "Finland #1")
r = T.check_import(doc("nodes", { node(), node({ remarks = "DE again" }) }), sections)
check("import: the same server twice in the file is added once ('duplicate')", #r.add == 1 and skip(r) == "duplicate:nil")
r = T.check_import(doc("nodes", { node({ uuid = "not-a-uuid" }), node({ address = "ok.example.net" }) }), sections)
check("import: an invalid entry is skipped with its field, valid ones are kept", #r.add == 1 and r.add[1].address == "ok.example.net" and skip(r) == "invalid:uuid")
for field, value in pairs({ port = "70000", address = "a b; reboot", protocol = "trojan", transport = "smoke", tls = "yes" }) do
	r = T.check_import(doc("nodes", { node({ [field] = value }) }), sections)
	check("import: invalid " .. field .. " is refused", #r.add == 0 and skip(r) == "invalid:" .. field)
end
r = T.check_import(doc("nodes", { node({ remarks = "x\ny" }) }), sections)
check("import: control characters in a value", #r.add == 0 and skip(r) == "invalid:remarks")
r = T.check_import(doc("nodes", { node({ remarks = { "a", "b" } }) }), sections)
check("import: a table where a string is expected", #r.add == 0 and skip(r) == "invalid:remarks")
r = T.check_import(doc("nodes", { node({ [".name"] = "global", [".type"] = "global", enabled = "1", node = "x", group = "Provider", add_mode = "2", md5 = "x" }) }), sections)
check("import: options that are not server options never reach UCI (dropped: " .. r.dropped .. ")",
	#r.add == 1 and r.dropped == 7 and r.add[1][".name"] == nil and r.add[1].enabled == nil and r.add[1].node == nil and r.add[1].group == nil and r.add[1].add_mode == "1")
r = T.check_import(doc("nodes", { "text", 5 }), sections)
check("import: entries that are not objects", #r.add == 0 and #r.skipped == 2)

check("import: file errors - not JSON, wrong format, version, kind, items", code("x") == "not_json" and code({ format = "x" }) == "not_export"
	and code(doc("nodes", { node() }, { version = 9 })) == "version" and code(doc("settings", { node() })) == "kind" and code(doc("nodes", "x")) == "items")
check("import: empty file", code(doc("nodes", {})) == "empty")
check("import: a rules file where servers were chosen", code(doc("rules", { { remarks = "R" } }), "nodes") == "kind_mismatch" and code(doc("rules", { { remarks = "R" } }), "rules") == "ok")
local many = {}
for i = 1, T.MAX_ITEMS + 1 do many[i] = node({ address = "h" .. i .. ".example.net" }) end
check("import: too many entries", code(doc("nodes", many)) == "too_large")
check("import: file too large", T.check_import(doc("nodes", { node() }), sections, nil, T.MAX_SIZE + 1).error.code == "too_large")

-- rules
r = T.check_import(doc("rules", { { remarks = "ADS", network = "tcp,udp", domain_list = "domain:ads.example.org\nregexp:^ad[0-9]+\\.", target = "_blackhole", port = "80,443,1000:2000" } }), sections)
check("import rule: conditions and a special target", r.ok and #r.add == 1 and r.add[1].target == "_blackhole" and r.add[1].port == "80,443,1000:2000")
r = T.check_import(doc("rules", { { remarks = "PROXY", network = "udp" } }), sections)
check("import rule: a rule with an existing name is not added", #r.add == 0 and skip(r) == "exists:nil")
for field, o in pairs({ target = { target = "srv1" }, port = { port = "0" }, network = { network = "icmp" }, protocol = { protocol = "ssh" },
	inbound = { inbound = "tun" }, source = { source = "lan" }, domain_list = { domain_list = "evil:x" }, sourcePort = { sourcePort = "1-2" },
	domain_resource = { domain_resource = { "../etc/passwd" } }, remarks = { remarks = "  " } }) do
	local item = { remarks = "R1" }
	for k, v in pairs(o) do item[k] = v end
	r = T.check_import(doc("rules", { item }), sections)
	check("import rule: invalid " .. field .. " is refused", #r.add == 0 and skip(r) == "invalid:" .. field)
end
r = T.check_import(doc("rules", { { remarks = "R2", domain_list = "domain:a.org\n# comment: x\nkeyword" } }), sections)
check("import rule: comments and keywords in a domain list are fine", #r.add == 1)

-- subscriptions
r = T.check_import(doc("subscriptions", { { remark = "New", url = "https://sub2.example.net/x", user_agent = "auto", hwid = "1" } }), sections)
check("import subscription: added", #r.add == 1 and r.add[1].user_agent == "auto")
r = T.check_import(doc("subscriptions", { { remark = "provider", url = "https://other.example.net/x" } }), sections)
check("import subscription: same name (case-insensitive) exists", #r.add == 0 and skip(r) == "exists:nil")
r = T.check_import(doc("subscriptions", { { remark = "Other name", url = "https://sub.example.net/list?token=abc" } }), sections)
check("import subscription: same URL exists", #r.add == 0 and skip(r) == "exists:nil")
for _, url in ipairs({ "ftp://x/y", "https://a b", "file:///etc/passwd", "https://x/'$(id)'", "javascript:alert(1)", "https://x/`id`" }) do
	r = T.check_import(doc("subscriptions", { { remark = "S", url = url } }), sections)
	check("import subscription: URL refused: " .. url, #r.add == 0 and skip(r) == "invalid:url")
end
r = T.check_import(doc("subscriptions", { { remark = "S", url = "https://x.example.net/a", excluded_node = { "0123456789abcdef X" }, md5 = "x" } }), sections)
check("import subscription: update state and deleted nodes are not imported", #r.add == 1 and r.add[1].excluded_node == nil and r.add[1].md5 == nil and r.dropped == 2)

-- round trip: export -> import into an empty configuration
local empty = T.parse_uci("config global 'global'\n")
for _, kind in ipairs({ "nodes", "rules", "subscriptions" }) do
	r = T.check_import(T.export(sections, kind), empty)
	check("round trip " .. kind .. ": every exported entry imports", r.ok and #r.skipped == 0 and #r.add == #T.export(sections, kind).items)
end

print(string.format("\n===== backup and import: %d passed, %d failed =====", pass, fail))
os.exit(fail == 0 and 0 or 1)
