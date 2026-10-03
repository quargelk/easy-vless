-- Easy VLESS 0.9.0 - node list state shared by subscribe.lua:
--   * identity of a subscription node (independent of its position in the
--     list, of its UCI section id and of its name),
--   * nodes deleted by the user (subscribe_list.excluded_node),
--   * merge of a subscription update into the existing nodes,
--   * references to a node, "Delete all nodes".
-- Pure functions over plain tables (UCI sections as uci_foreach returns
-- them): no UCI access, no shell - tests/nodes-test.lua runs them with a
-- stock Lua 5.1.

local M = {}

-- Most entries a subscription keeps in excluded_node (the oldest are dropped).
M.MAX_EXCLUDED = 500

-- What makes two subscription entries "the same server". The name is not
-- part of it (providers rename nodes, e.g. with the remaining traffic), nor
-- are options that only tune the connection (flow, fingerprint, ALPN, the
-- Reality key): a change of those is an update of the same node.
local IDENTITY = {
	"protocol", "address", "port", "uuid", "transport", "tls_serverName",
	"ws_host", "ws_path", "grpc_serviceName", "httpupgrade_host", "httpupgrade_path",
	"xhttp_host", "xhttp_path", "http_host", "http_path"
}

-- Options compared to tell "updated" from "unchanged" (reporting only).
local IGNORED_IN_DIFF = { add_mode = true, group = true }

local function str(v)
	if v == nil then return "" end
	if type(v) == "table" then
		local t = {}
		for i = 1, #v do t[i] = tostring(v[i]) end
		return table.concat(t, ",")
	end
	return tostring(v)
end

function M.identity(node)
	local parts = {}
	for i, k in ipairs(IDENTITY) do
		local v = str(node[k])
		if k == "address" or k == "tls_serverName" then v = v:lower() end
		parts[i] = v
	end
	return table.concat(parts, "\n")
end

-- Two independent multiplicative hashes (32 bit each, exact in Lua numbers),
-- 16 hex digits. Not cryptographic: it only has to tell the nodes of one
-- subscription apart, and it does not expose the UUID it is computed over.
local function hash(s, seed, mul)
	local h = seed
	for i = 1, #s do
		h = (h * mul + s:byte(i)) % 4294967296
	end
	return h
end

function M.key(node)
	local id = M.identity(node)
	return string.format("%08x%08x", hash(id, 5381, 33), hash(id, 2166136261, 131))
end

function M.is_server(s)
	return s[".type"] == "nodes" and type(s.protocol) == "string" and s.protocol:sub(1, 1) ~= "_"
end

function M.is_subscribed(s)
	return M.is_server(s) and s.add_mode == "2" and (s.group or "") ~= ""
end

local function same_group(a, b)
	return (a or ""):lower() == (b or ""):lower()
end

-- ---------------------------------------------------------------- excluded

-- excluded_node entries: "<key> <name at the time of the deletion>"
function M.excluded_map(list)
	local map, order = {}, {}
	if type(list) == "string" then list = { list } end
	for _, v in ipairs(list or {}) do
		local key, label = tostring(v):match("^(%x+)%s*(.-)%s*$")
		if key and #key == 16 and map[key] == nil then
			map[key] = label
			order[#order + 1] = key
		end
	end
	return map, order
end

local function excluded_entry(key, label)
	label = str(label):gsub("[%c]", " "):sub(1, 80)
	return (label ~= "") and (key .. " " .. label) or key
end

-- The list with this node added (once; the oldest entries go first when the
-- list is full).
function M.exclude(list, node)
	local map, order = M.excluded_map(list)
	local key = M.key(node)
	if map[key] == nil then
		order[#order + 1] = key
	end
	map[key] = str(node.remarks)
	local out = {}
	for i = math.max(1, #order - M.MAX_EXCLUDED + 1), #order do
		out[#out + 1] = excluded_entry(order[i], map[order[i]])
	end
	return out
end

-- The list without one key (key == nil: without all of them).
function M.restore(list, key)
	local map, order = M.excluded_map(list)
	local out = {}
	if key == nil then return out, #order end
	local n = 0
	for _, k in ipairs(order) do
		if k == key then
			n = n + 1
		else
			out[#out + 1] = excluded_entry(k, map[k])
		end
	end
	return out, n
end

-- Nodes of a downloaded subscription without the ones the user deleted.
function M.filter_excluded(incoming, excluded_list)
	local map = M.excluded_map(excluded_list)
	if next(map) == nil then return incoming, 0 end
	local kept, skipped = {}, 0
	for _, node in ipairs(incoming) do
		if map[M.key(node)] ~= nil then
			skipped = skipped + 1
		else
			kept[#kept + 1] = node
		end
	end
	return kept, skipped
end

-- ---------------------------------------------------------------- merge

local function differs(old, new)
	for k, v in pairs(new) do
		if not IGNORED_IN_DIFF[k] and str(old[k]) ~= str(v) then return true end
	end
	return false
end

-- A subscription update: which downloaded node is which existing one.
--   existing  the nodes of this subscription now (UCI sections)
--   incoming  the downloaded nodes (already without the excluded ones)
-- Returns ids (ids[i] = section id to keep for incoming[i], nil = new node)
-- and counts { new, updated, unchanged, removed }. Nodes are matched by
-- identity only: reordering the subscription or inserting nodes changes
-- nothing, a renamed node stays the same node.
function M.merge(existing, incoming)
	local by_key = {}
	for _, s in ipairs(existing or {}) do
		local k = M.key(s)
		by_key[k] = by_key[k] or {}
		table.insert(by_key[k], s)
	end
	local ids, stats = {}, { new = 0, updated = 0, unchanged = 0, removed = 0 }
	local used = 0
	for i, node in ipairs(incoming) do
		local same = by_key[M.key(node)]
		local old = same and table.remove(same, 1)
		if old then
			ids[i] = old[".name"]
			used = used + 1
			if differs(old, node) then
				stats.updated = stats.updated + 1
			else
				stats.unchanged = stats.unchanged + 1
			end
		else
			stats.new = stats.new + 1
		end
	end
	stats.removed = #(existing or {}) - used
	return ids, stats
end

-- ---------------------------------------------------------------- references

local function find(sections, name)
	for _, s in ipairs(sections) do
		if s[".name"] == name then return s end
	end
end

local function rule_ids(sections)
	local t = {}
	for _, s in ipairs(sections) do
		if s[".type"] == "shunt_rules" then t[#t + 1] = s[".name"] end
	end
	return t
end

local function contains(list, v)
	if type(list) == "string" then return list == v end
	for _, x in ipairs(list or {}) do
		if x == v then return true end
	end
	return false
end

-- Everything that points to node id: { { section, option, kind } }, kind =
-- "main" (global.node), "default" / "rule" / "preproxy" (Main Router
-- entries), "group" (URL Test group member), "chain" (preproxy_node/to_node).
function M.references(sections, id)
	local refs = {}
	local rules = rule_ids(sections)
	for _, s in ipairs(sections) do
		if s[".type"] == "global" and s.node == id then
			refs[#refs + 1] = { section = s[".name"], option = "node", kind = "main" }
		elseif s[".type"] == "nodes" and s[".name"] ~= id then
			if s.protocol == "_shunt" then
				if s.default_node == id then
					refs[#refs + 1] = { section = s[".name"], option = "default_node", kind = "default" }
				end
				if s.default_proxy_tag == id then
					refs[#refs + 1] = { section = s[".name"], option = "default_proxy_tag", kind = "preproxy" }
				end
				for _, r in ipairs(rules) do
					if s[r] == id then
						refs[#refs + 1] = { section = s[".name"], option = r, kind = "rule" }
					end
					if s[r .. "_proxy_tag"] == id then
						refs[#refs + 1] = { section = s[".name"], option = r .. "_proxy_tag", kind = "preproxy" }
					end
				end
			elseif s.protocol == "_urltest" then
				if contains(s.urltest_node, id) then
					refs[#refs + 1] = { section = s[".name"], option = "urltest_node", kind = "group" }
				end
			else
				for _, o in ipairs({ "preproxy_node", "to_node" }) do
					if s[o] == id then
						refs[#refs + 1] = { section = s[".name"], option = o, kind = "chain" }
					end
				end
			end
		end
	end
	return refs
end

-- The subscription (subscribe_list section) a node came from, or nil.
function M.subscription_of(sections, node)
	if not M.is_subscribed(node) then return nil end
	for _, s in ipairs(sections) do
		if s[".type"] == "subscribe_list" and same_group(s.remark, node.group) then
			return s
		end
	end
end

-- Delete one server. Refused while something still points to it (the caller
-- shows where). A subscription node is remembered in its subscription's
-- excluded_node list, so the next update does not bring it back.
-- Returns plan { remove = { id }, set = { { section, option, value } } }
-- or nil, error code ("unknown" | "used"), references.
function M.plan_delete(sections, id)
	local node = find(sections, id)
	if not node or not M.is_server(node) then
		return nil, "unknown"
	end
	local refs = M.references(sections, id)
	if #refs > 0 then
		return nil, "used", refs
	end
	local plan = { remove = { id }, set = {}, del = {}, excluded = false }
	local sub = M.subscription_of(sections, node)
	if sub then
		plan.set[1] = { sub[".name"], "excluded_node", M.exclude(sub.excluded_node, node) }
		plan.excluded = true
	end
	return plan
end

-- "Delete all nodes": every server is removed; subscriptions, rules and
-- settings stay. What pointed to a removed server is put into a state that
-- still starts:
--   URL Test group       loses its servers; a group left empty is removed too
--   Main Router Default  Direct
--   Main Router rule     "Default target" (the rule itself and its place in
--                        the order are kept; it follows Default again as soon
--                        as a server is used)
--   preproxy / chain     the option is removed
--   main node            cleared, main switch off (nothing to start); the
--                        Main Router as main node stays
-- Subscription nodes are not marked as deleted by the user: the next update
-- of a subscription brings its servers back (its md5 is dropped so that an
-- unchanged list is imported again).
-- Returns plan { remove, set, del, stop, groups_removed, counts, changes };
-- changes = what else is touched, for the confirmation dialog:
-- { kind = "group_removed" | "group_shrunk" | "default" | "rule" | "main", name }.
function M.plan_delete_all(sections)
	local plan = { remove = {}, set = {}, del = {}, stop = false, groups_removed = {}, changes = {},
		counts = { manual = 0, subscription = 0, groups = 0, references = 0 } }
	local gone = {}
	local subs_touched = {}
	for _, s in ipairs(sections) do
		if M.is_server(s) then
			gone[s[".name"]] = true
			plan.remove[#plan.remove + 1] = s[".name"]
			if M.is_subscribed(s) then
				plan.counts.subscription = plan.counts.subscription + 1
				subs_touched[s.group:lower()] = true
			else
				plan.counts.manual = plan.counts.manual + 1
			end
		end
	end
	-- groups first: an emptied group is gone as well
	for _, s in ipairs(sections) do
		if s[".type"] == "nodes" and s.protocol == "_urltest" then
			local members = type(s.urltest_node) == "table" and s.urltest_node or { s.urltest_node }
			local left = {}
			for _, m in ipairs(members) do
				if not gone[m] then left[#left + 1] = m end
			end
			if #left == 0 then
				gone[s[".name"]] = true
				plan.remove[#plan.remove + 1] = s[".name"]
				plan.groups_removed[#plan.groups_removed + 1] = s.remarks or s[".name"]
				plan.counts.groups = plan.counts.groups + 1
				plan.changes[#plan.changes + 1] = { kind = "group_removed", name = s.remarks or s[".name"] }
			elseif #left ~= #members then
				plan.set[#plan.set + 1] = { s[".name"], "urltest_node", left }
				plan.changes[#plan.changes + 1] = { kind = "group_shrunk", name = s.remarks or s[".name"] }
			end
		end
	end
	local rules = rule_ids(sections)
	for _, s in ipairs(sections) do
		if s[".type"] == "global" and s.node and gone[s.node] then
			plan.del[#plan.del + 1] = { s[".name"], "node" }
			plan.set[#plan.set + 1] = { s[".name"], "enabled", "0" }
			plan.stop = true
			plan.counts.references = plan.counts.references + 1
			plan.changes[#plan.changes + 1] = { kind = "main", name = "" }
		elseif s[".type"] == "nodes" and not gone[s[".name"]] then
			if s.protocol == "_shunt" then
				if s.default_node and gone[s.default_node] then
					plan.set[#plan.set + 1] = { s[".name"], "default_node", "_direct" }
					plan.counts.references = plan.counts.references + 1
					plan.changes[#plan.changes + 1] = { kind = "default", name = "" }
				end
				if s.default_proxy_tag and gone[s.default_proxy_tag] then
					plan.del[#plan.del + 1] = { s[".name"], "default_proxy_tag" }
				end
				for _, r in ipairs(rules) do
					if s[r] and gone[s[r]] then
						plan.set[#plan.set + 1] = { s[".name"], r, "_default" }
						plan.counts.references = plan.counts.references + 1
						plan.changes[#plan.changes + 1] = { kind = "rule", name = (find(sections, r) or {}).remarks or r }
					end
					if s[r .. "_proxy_tag"] and gone[s[r .. "_proxy_tag"]] then
						plan.del[#plan.del + 1] = { s[".name"], r .. "_proxy_tag" }
					end
				end
			end
		elseif s[".type"] == "subscribe_list" and subs_touched[(s.remark or ""):lower()] and s.md5 then
			plan.del[#plan.del + 1] = { s[".name"], "md5" }
		end
	end
	return plan
end

-- After a plan: is there anything left that points to a missing node?
-- (regression guard used by the tests and by subscribe.lua before commit)
function M.dangling(sections)
	local exists = {}
	for _, s in ipairs(sections) do
		if s[".type"] == "nodes" then exists[s[".name"]] = true end
	end
	local special = { _direct = true, _blackhole = true, _default = true, [""] = true }
	local bad = {}
	local rules = rule_ids(sections)
	for _, s in ipairs(sections) do
		if s[".type"] == "global" and s.node and s.node ~= "" and not exists[s.node] then
			bad[#bad + 1] = s[".name"] .. ".node"
		elseif s[".type"] == "nodes" and s.protocol == "_shunt" then
			local opts = { "default_node" }
			for _, r in ipairs(rules) do opts[#opts + 1] = r end
			for _, o in ipairs(opts) do
				local v = s[o]
				if v and not special[v] and not exists[v] then
					bad[#bad + 1] = s[".name"] .. "." .. o
				end
			end
		elseif s[".type"] == "nodes" and s.protocol == "_urltest" then
			local members = type(s.urltest_node) == "table" and s.urltest_node or { s.urltest_node }
			for _, m in ipairs(members) do
				if not exists[m] then bad[#bad + 1] = s[".name"] .. ".urltest_node" break end
			end
			if #members == 0 then bad[#bad + 1] = s[".name"] .. ".urltest_node" end
		end
	end
	return bad
end

return M
