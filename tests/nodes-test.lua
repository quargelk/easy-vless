-- Easy VLESS - node list state (0.9.0): unit / regression test of
-- root/usr/lib/lua/luci/easy_vless/nodes.lua with a stock Lua 5.1 (no UCI).
--
--   lua5.1 tests/nodes-test.lua      (static checks, CI "checks" job)
--
-- Covered: identity of a subscription node (not its position, section id or
-- name), nodes deleted by the user stay deleted, merge of an update (new /
-- updated / unchanged / removed, ids kept), restore, references, deleting a
-- server, "Delete all nodes" (main node, Default, rule targets, URL Test
-- groups, subscriptions) without dangling references.

package.path = "root/usr/lib/lua/?.lua;" .. package.path
local N = require "luci.easy_vless.nodes"

local pass, fail = 0, 0
local function check(msg, cond)
	if cond then pass = pass + 1 print("PASS: " .. msg)
	else fail = fail + 1 print("FAIL: " .. msg) end
end

local function vless(name, addr, extra)
	local t = { protocol = "vless", type = "sing-box", remarks = name, address = addr, port = "443",
		uuid = "00000000-0000-4000-8000-000000000001", transport = "tcp", tls = "1", add_mode = "2", group = "Provider" }
	for k, v in pairs(extra or {}) do t[k] = v end
	return t
end
local function section(id, t)
	t[".name"] = id
	t[".type"] = t[".type"] or "nodes"
	return t
end

-- ---------------------------------------------------------------- identity
local fi, de, nl = vless("Finland", "fi.example.net"), vless("Germany", "de.example.net"), vless("Netherlands", "nl.example.net")
check("key: 16 hex digits", N.key(fi):match("^%x+$") and #N.key(fi) == 16)
check("key: same node, same key", N.key(fi) == N.key(vless("Finland", "fi.example.net")))
check("key: the name is not part of the identity", N.key(fi) == N.key(vless("Finland | 12 GB left", "fi.example.net")))
check("key: the address is case-insensitive", N.key(fi) == N.key(vless("Finland", "FI.Example.NET")))
check("key: another address is another node", N.key(fi) ~= N.key(de))
check("key: another port is another node", N.key(fi) ~= N.key(vless("Finland", "fi.example.net", { port = "8443" })))
check("key: another UUID is another node", N.key(fi) ~= N.key(vless("Finland", "fi.example.net", { uuid = "00000000-0000-4000-8000-000000000002" })))
check("key: another transport path is another node", N.key(vless("a", "cdn.example.net", { transport = "ws", ws_path = "/a" })) ~= N.key(vless("a", "cdn.example.net", { transport = "ws", ws_path = "/b" })))
check("key: connection tuning (flow, fingerprint, Reality key) is the same node",
	N.key(fi) == N.key(vless("Finland", "fi.example.net", { flow = "xtls-rprx-vision", fingerprint = "chrome", reality_publicKey = "KEY2" })))
check("key: does not contain the UUID or the address", not N.key(fi):find("0000", 1, true) and not N.identity(fi):find("Finland", 1, true))
check("key: section id and position play no role", N.key(section("abc", vless("Finland", "fi.example.net"))) == N.key(fi))

-- ---------------------------------------------------------------- deleted by the user
local excluded = N.exclude(nil, de)
check("exclude: one entry '<key> <name>'", #excluded == 1 and excluded[1] == N.key(de) .. " Germany")
check("exclude: the same node twice is one entry", #N.exclude(excluded, de) == 1)
check("exclude: a UCI option with one value (string) is read too", #N.exclude(excluded[1], fi) == 2)
local map = N.excluded_map(excluded)
check("excluded_map: key -> name", map[N.key(de)] == "Germany")
check("excluded_map: garbage is ignored", next((N.excluded_map({ "not a key", "", "12345" }))) == nil)

local kept, skipped = N.filter_excluded({ fi, de, nl }, excluded)
check("update: the deleted node is not imported again", #kept == 2 and skipped == 1 and kept[1] == fi and kept[2] == nl)
kept, skipped = N.filter_excluded({ nl, vless("Germany (renamed)", "de.example.net"), fi }, excluded)
check("update: still deleted after the provider reordered and renamed it", #kept == 2 and skipped == 1 and kept[1] == nl and kept[2] == fi)
kept, skipped = N.filter_excluded({ fi, de }, nil)
check("update: nothing deleted, nothing filtered", #kept == 2 and skipped == 0)
kept, skipped = N.filter_excluded({ de }, excluded)
check("update: every node deleted by the user -> empty list", #kept == 0 and skipped == 1)

local many = {}
for i = 1, N.MAX_EXCLUDED + 20 do
	many = N.exclude(many, vless("n" .. i, "h" .. i .. ".example.net"))
end
check("exclude: the list is bounded (" .. #many .. ")", #many == N.MAX_EXCLUDED)
check("exclude: the newest entries are kept", N.excluded_map(many)[N.key(vless("x", "h" .. (N.MAX_EXCLUDED + 20) .. ".example.net"))] ~= nil
	and N.excluded_map(many)[N.key(vless("x", "h1.example.net"))] == nil)
check("exclude: control characters in a name do not break the entry", N.exclude(nil, vless("a\nb\tc", "x.example.net"))[1]:match("^%x+ a b c$") ~= nil)

-- restore
local two = N.exclude(excluded, fi)
local left, n = N.restore(two, N.key(de))
check("restore one: only that node comes back", n == 1 and #left == 1 and N.excluded_map(left)[N.key(fi)] == "Finland")
left, n = N.restore(two, nil)
check("restore all", n == 2 and #left == 0)
left, n = N.restore(two, "0000000000000000")
check("restore an unknown key: nothing changes", n == 0 and #left == 2)
kept, skipped = N.filter_excluded({ fi, de, nl }, N.restore(two, N.key(de)))
check("restored node is imported again, the other stays deleted", #kept == 2 and kept[1] == de and kept[2] == nl)

-- ---------------------------------------------------------------- merge of an update
local existing = { section("id_fi", vless("Finland", "fi.example.net")), section("id_de", vless("Germany", "de.example.net")), section("id_nl", vless("Netherlands", "nl.example.net")) }
local ids, st = N.merge(existing, { vless("Finland", "fi.example.net"), vless("Germany", "de.example.net"), vless("Netherlands", "nl.example.net") })
check("merge: unchanged list keeps every id", ids[1] == "id_fi" and ids[2] == "id_de" and ids[3] == "id_nl" and st.unchanged == 3 and st.new == 0 and st.updated == 0 and st.removed == 0)
ids, st = N.merge(existing, { vless("Netherlands", "nl.example.net"), vless("Sweden", "se.example.net"), vless("Finland", "fi.example.net") })
check("merge: reordered list - ids follow the nodes, not the positions", ids[1] == "id_nl" and ids[2] == nil and ids[3] == "id_fi")
check("merge: one new, one missing in the answer, two unchanged", st.new == 1 and st.removed == 1 and st.unchanged == 2 and st.updated == 0)
ids, st = N.merge(existing, { vless("Finland #1", "fi.example.net", { flow = "xtls-rprx-vision" }), vless("Germany", "de.example.net"), vless("Netherlands", "nl.example.net") })
check("merge: a renamed / re-tuned node is updated and keeps its id", ids[1] == "id_fi" and st.updated == 1 and st.unchanged == 2 and st.new == 0)
ids, st = N.merge(existing, { vless("Finland", "fi.example.net"), vless("Finland copy", "fi.example.net") })
check("merge: a duplicate in the answer gets a new id (an id is used once)", ids[1] == "id_fi" and ids[2] == nil and st.new == 1 and st.removed == 2)
ids, st = N.merge(nil, { fi, de })
check("merge: first import - everything is new", ids[1] == nil and ids[2] == nil and st.new == 2 and st.removed == 0)
ids, st = N.merge(existing, {})
check("merge: empty list - everything removed", st.removed == 3 and st.new == 0)
-- deleted by the user + update: deleted stays away, the others keep their ids
kept, skipped = N.filter_excluded({ vless("Germany", "de.example.net"), vless("Finland", "fi.example.net"), vless("Sweden", "se.example.net") }, N.exclude(nil, de))
ids, st = N.merge({ existing[1], existing[3] }, kept)
check("deleted node + update: not back, Finland keeps its id, Sweden is new, Netherlands is removed",
	skipped == 1 and #kept == 2 and ids[1] == "id_fi" and ids[2] == nil and st.new == 1 and st.removed == 1 and st.unchanged == 1)

-- ---------------------------------------------------------------- configuration fixture
local function config(node, default, targets)
	local router = { protocol = "_shunt", remarks = "Main Router", default_node = default }
	for k, v in pairs(targets or {}) do router[k] = v end
	return {
		section("global", { [".type"] = "global", node = node, enabled = "1" }),
		section("m1", { protocol = "vless", remarks = "Manual", address = "m.example.net", port = "443", uuid = "u", add_mode = "0" }),
		section("s1", vless("Finland", "fi.example.net")),
		section("s2", vless("Germany", "de.example.net")),
		section("o1", vless("Other", "o.example.net", { group = "Other provider" })),
		section("g1", { protocol = "_urltest", remarks = "Fastest", urltest_node = { "s1", "s2" } }),
		section("RUSSIA", { [".type"] = "shunt_rules", remarks = "RUSSIA" }),
		section("PROXY", { [".type"] = "shunt_rules", remarks = "PROXY" }),
		section("UDP", { [".type"] = "shunt_rules", remarks = "UDP" }),
		section("main_router", router),
		section("cfg01", { [".type"] = "subscribe_list", remark = "provider", url = "https://sub.example.net/a", md5 = "abc" }),
		section("cfg02", { [".type"] = "subscribe_list", remark = "Other provider", url = "https://sub.example.net/b" }),
	}
end
local function apply(sections, plan)
	local out = {}
	local gone = {}
	for _, id in ipairs(plan.remove or {}) do gone[id] = true end
	for _, s in ipairs(sections) do
		if not gone[s[".name"]] then
			local copy = {}
			for k, v in pairs(s) do copy[k] = v end
			out[#out + 1] = copy
		end
	end
	local function find(id) for _, s in ipairs(out) do if s[".name"] == id then return s end end end
	for _, v in ipairs(plan.set or {}) do find(v[1])[v[2]] = v[3] end
	for _, v in ipairs(plan.del or {}) do find(v[1])[v[2]] = nil end
	return out, find
end
local function kinds(refs)
	local t = {}
	for _, r in ipairs(refs) do t[#t + 1] = r.kind .. ":" .. r.option end
	table.sort(t)
	return table.concat(t, " ")
end

-- references
local cfg = config("main_router", "s1", { RUSSIA = "_direct", PROXY = "s1", UDP = "g1" })
check("references: Default, rule target and group member (" .. kinds(N.references(cfg, "s1")) .. ")", kinds(N.references(cfg, "s1")) == "default:default_node group:urltest_node rule:PROXY")
check("references: a group as rule target", kinds(N.references(cfg, "g1")) == "rule:UDP")
check("references: unused server", #N.references(cfg, "m1") == 0)
check("references: main node", kinds(N.references(config("m1", "_direct"), "m1")) == "main:node")
check("no dangling reference in the fixture", #N.dangling(cfg) == 0)

-- delete one server
local plan, err, refs = N.plan_delete(cfg, "s1")
check("delete: refused while the server is used, with the references", plan == nil and err == "used" and #refs == 3)
plan, err = N.plan_delete(cfg, "nope")
check("delete: unknown id", plan == nil and err == "unknown")
plan, err = N.plan_delete(cfg, "main_router")
check("delete: the Main Router is not a server", plan == nil and err == "unknown")
plan, err = N.plan_delete(cfg, "g1")
check("delete: a URL Test group is not a server", plan == nil and err == "unknown")
plan = N.plan_delete(cfg, "m1")
check("delete: manual server - removed, nothing remembered", plan and plan.remove[1] == "m1" and #plan.set == 0 and plan.excluded == false)
plan = N.plan_delete(cfg, "o1")
check("delete: subscription server - remembered in its own subscription (matched by name, case-insensitive)",
	plan and plan.excluded and plan.set[1][1] == "cfg02" and plan.set[1][2] == "excluded_node" and plan.set[1][3][1] == N.key(cfg[5]) .. " Other")
local after, find = apply(cfg, plan)
check("delete: the next update of that subscription does not import it again",
	select(2, N.filter_excluded({ vless("Other", "o.example.net", { group = "Other provider" }) }, find("cfg02").excluded_node)) == 1)
check("delete: another subscription with the same server is not affected", find("cfg01").excluded_node == nil)
check("delete: nothing dangling", #N.dangling(after) == 0)
local orphan = config("main_router", "_direct")
orphan[#orphan] = nil
plan = N.plan_delete(orphan, "o1")
check("delete: node of a deleted subscription - removed, nothing to remember", plan and not plan.excluded and #plan.set == 0)

-- ---------------------------------------------------------------- Delete all nodes
plan = N.plan_delete_all(cfg)
after, find = apply(cfg, plan)
check("delete all: counts (" .. plan.counts.manual .. " manual, " .. plan.counts.subscription .. " subscription, " .. plan.counts.groups .. " group)",
	plan.counts.manual == 1 and plan.counts.subscription == 3 and plan.counts.groups == 1)
check("delete all: no server and no emptied group left", find("m1") == nil and find("s1") == nil and find("s2") == nil and find("o1") == nil and find("g1") == nil)
check("delete all: Default -> Direct", find("main_router").default_node == "_direct")
check("delete all: rule targets on a server or on the removed group -> Default target; Direct is kept",
	find("main_router").PROXY == "_default" and find("main_router").UDP == "_default" and find("main_router").RUSSIA == "_direct")
check("delete all: rules, subscriptions and the Main Router are kept", find("PROXY") and find("UDP") and find("RUSSIA") and find("cfg01") and find("cfg02") and find("main_router"))
check("delete all: the Main Router stays the main node, the service is not stopped", find("global").node == "main_router" and find("global").enabled == "1" and plan.stop == false)
check("delete all: subscriptions import their list again on the next update (md5 dropped)", find("cfg01").md5 == nil)
check("delete all: nothing is marked as deleted by the user", find("cfg01").excluded_node == nil and find("cfg02").excluded_node == nil)
check("delete all: no dangling reference", #N.dangling(after) == 0)
local ck = {}
for _, c in ipairs(plan.changes) do ck[#ck + 1] = c.kind .. ":" .. c.name end
table.sort(ck)
check("delete all: changes for the dialog (" .. table.concat(ck, " ") .. ")", table.concat(ck, " ") == "default: group_removed:Fastest rule:PROXY rule:UDP")

cfg = config("s1", "_direct")
plan = N.plan_delete_all(cfg)
after, find = apply(cfg, plan)
check("delete all, a server is the main node: main node cleared, main switch off, service stopped",
	find("global").node == nil and find("global").enabled == "0" and plan.stop == true and #N.dangling(after) == 0)
cfg = config("g1", "_direct")
plan = N.plan_delete_all(cfg)
after, find = apply(cfg, plan)
check("delete all, a group is the main node: the same", find("global").node == nil and plan.stop == true and #N.dangling(after) == 0)

cfg = config("main_router", "_direct", { RUSSIA = "_direct" })
cfg[6].urltest_node = { "s1", "main_router" }   -- a group with a member that is not a server
plan = N.plan_delete_all(cfg)
after, find = apply(cfg, plan)
check("delete all: a group that keeps a member is kept and shrunk", find("g1") and #find("g1").urltest_node == 1 and plan.counts.groups == 0)
check("delete all: Default Direct and Direct rules are untouched", plan.counts.references == 0 and find("main_router").default_node == "_direct")

local empty = { section("global", { [".type"] = "global", node = "main_router" }), section("main_router", { protocol = "_shunt", default_node = "_direct" }) }
plan = N.plan_delete_all(empty)
check("delete all without servers: nothing to do", #plan.remove == 0 and #plan.set == 0 and #plan.del == 0 and plan.stop == false)

check("dangling: detects a missing main node, target and group member",
	#N.dangling({ section("global", { [".type"] = "global", node = "gone" }), section("R", { [".type"] = "shunt_rules" }),
		section("main_router", { protocol = "_shunt", default_node = "gone", R = "gone" }), section("g", { protocol = "_urltest", urltest_node = { "gone" } }) }) == 4)

print(string.format("\n===== node list state: %d passed, %d failed =====", pass, fail))
os.exit(fail == 0 and 0 or 1)
