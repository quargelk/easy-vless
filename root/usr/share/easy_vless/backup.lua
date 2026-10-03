#!/usr/bin/lua
-- Easy VLESS 0.9.0 - Backup / Restore and Import / Export for LuCI (rpcd
-- "transfer"). Reads one JSON object { action, data, kind } on stdin and
-- prints one JSON object on stdout.
--
--   backup              the complete state as a file (content + file name)
--   restore_check       is this file a backup that can be restored? what is in it?
--   restore_apply       replace the configuration with the backup
--   rollback            put back the configuration from before the last restore
--   state               is there something to roll back to?
--   export              kind = nodes | rules | subscriptions
--   import_check        what would be added / skipped, and why
--   import_apply        add the entries
--
-- The decisions (formats, validation) are in luci/easy_vless/transfer.lua.
-- A file is validated completely before anything is written; restore keeps a
-- copy of the previous configuration (ROLLBACK_DIR) and puts it back itself
-- when a step fails.

local api = require "luci.easy_vless.api"
local T = require "luci.easy_vless.transfer"
local jsonc = api.jsonc
local fs = api.fs

local CONFIG = api.c_config
local CONFIG_FILE = "/etc/config/" .. CONFIG
local STATE_DIR = "/etc/" .. CONFIG
local HWID_FILE = STATE_DIR .. "/hwid"
local DIRECT_IP_FILE = "/usr/share/" .. CONFIG .. "/direct_ip"
local ROLLBACK_DIR = STATE_DIR .. "/restore-backup"
local SUB_LOCK = api.LOCK_PREFIX .. "_subscribe.lock"
local INIT_LOCK = api.LOCK_PREFIX .. ".lock"

local function q(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function sh(cmd)
	local p = io.popen(cmd .. " 2>/dev/null")
	if not p then return "" end
	local out = p:read("*a") or ""
	p:close()
	return out
end

local function call(cmd)
	return os.execute(cmd .. " >/dev/null 2>&1") == 0
end

local function readfile(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local c = f:read("*a")
	f:close()
	return c
end

-- write through a temporary file in the same directory, then rename
local function writefile(path, content, mode)
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then return false end
	local ok = f:write(content)
	f:close()
	if not ok then
		os.remove(tmp)
		return false
	end
	if mode then call("chmod " .. mode .. " " .. q(tmp)) end
	return os.rename(tmp, path) and true or false
end

-- sha256 of a string: through a file, never on a command line
local function sha256(text)
	local tmp = (sh("mktemp /tmp/" .. CONFIG .. "_hash.XXXXXX"):gsub("%s+$", ""))
	if tmp == "" then return "" end
	local f = io.open(tmp, "w")
	if not f then return "" end
	f:write(text)
	f:close()
	local out = sh("sha256sum " .. q(tmp))
	os.remove(tmp)
	return out:match("^(%x+)") or ""
end

local function app_version()
	local v = sh("opkg list-installed " .. CONFIG:gsub("_", "-") .. " | awk '{print $3}'"):gsub("%s+", "")
	if v == "" then
		v = (sh("apk list -I easy-vless | head -n1"):match("easy%-vless%-([%w%.%-_]+)") or "")
	end
	return v ~= "" and v or nil
end

local function sections()
	local t = {}
	for _, stype in ipairs({ "global", "nodes", "shunt_rules", "subscribe_list" }) do
		api.uci_foreach_c(stype, function(s) t[#t + 1] = s end)
	end
	return t
end

local function busy()
	if fs.access(SUB_LOCK) then return "subscription" end
	if fs.access(INIT_LOCK) then return "service" end
	return nil
end

local function stamp()
	return os.date("%Y%m%d-%H%M")
end

-- ---------------------------------------------------------------- backup / restore

local function cmd_backup()
	local config = readfile(CONFIG_FILE)
	if not config or config == "" then
		return { ok = false, error = { code = "no_config" } }
	end
	if #config > T.MAX_SIZE * 0.7 then
		return { ok = false, error = { code = "too_large", max = T.MAX_SIZE } }
	end
	local files = { config = config, hwid = readfile(HWID_FILE), direct_ip = readfile(DIRECT_IP_FILE) }
	local doc = T.make_backup(files, { app_version = app_version(), created = os.time(),
		hostname = (readfile("/proc/sys/kernel/hostname") or ""):gsub("%s+$", "") }, sha256)
	return { ok = true, filename = "easy-vless-backup-" .. stamp() .. ".json", content = jsonc.stringify(doc) }
end

local function decode(data)
	if type(data) ~= "string" or data == "" then return nil, 0 end
	return jsonc.parse(data), #data
end

local function cmd_restore_check(data)
	local doc, size = decode(data)
	return T.check_backup(doc, sha256, size)
end

local function save_rollback()
	if not call("mkdir -p " .. q(ROLLBACK_DIR)) then return false end
	call("chmod 700 " .. q(ROLLBACK_DIR))
	if not call("cp -f " .. q(CONFIG_FILE) .. " " .. q(ROLLBACK_DIR .. "/config")) then return false end
	call("rm -f " .. q(ROLLBACK_DIR .. "/hwid") .. " " .. q(ROLLBACK_DIR .. "/direct_ip"))
	if fs.access(HWID_FILE) then call("cp -f " .. q(HWID_FILE) .. " " .. q(ROLLBACK_DIR .. "/hwid")) end
	if fs.access(DIRECT_IP_FILE) then call("cp -f " .. q(DIRECT_IP_FILE) .. " " .. q(ROLLBACK_DIR .. "/direct_ip")) end
	return writefile(ROLLBACK_DIR .. "/time", tostring(os.time()))
end

-- Put a set of files in place: { config, hwid, direct_ip } (nil = leave).
local function install(files)
	-- the real parser has the last word: uci must load the new file
	local dir = (sh("mktemp -d /tmp/" .. CONFIG .. "_restore.XXXXXX"):gsub("%s+$", ""))
	if dir == "" then return false, "tmp" end
	local ok = writefile(dir .. "/" .. CONFIG, files.config, "600") and call("uci -c " .. q(dir) .. " show " .. CONFIG)
	call("rm -rf " .. q(dir))
	if not ok then return false, "uci" end
	if not writefile(CONFIG_FILE, files.config, "600") then return false, "write" end
	if files.hwid and files.hwid ~= "" then
		call("mkdir -p " .. q(STATE_DIR))
		if not writefile(HWID_FILE, files.hwid) then return false, "write" end
	end
	if files.direct_ip then
		if not writefile(DIRECT_IP_FILE, files.direct_ip) then return false, "write" end
	end
	-- changes staged in a LuCI session belong to the replaced configuration
	call("uci -q revert " .. CONFIG)
	return true
end

local function service_for()
	return sh("uci -q get " .. CONFIG .. ".@global[0].enabled"):gsub("%s+", "") == "1" and "restart" or "stop"
end

local function cmd_restore_apply(data)
	local doc, size = decode(data)
	local res = T.check_backup(doc, sha256, size)
	if not res.ok then return res end
	local b = busy()
	if b then return { ok = false, error = { code = "busy", what = b } } end
	if not save_rollback() then
		return { ok = false, error = { code = "rollback_copy" } }
	end
	local ok, why = install(doc.files)
	if not ok then
		-- nothing half-written is left behind
		local back = { config = readfile(ROLLBACK_DIR .. "/config"), hwid = readfile(ROLLBACK_DIR .. "/hwid"), direct_ip = readfile(ROLLBACK_DIR .. "/direct_ip") }
		local restored = back.config and install(back)
		return { ok = false, error = { code = "apply", step = why, restored = restored and true or false } }
	end
	res.service = service_for()
	res.rollback = true
	return res
end

local function cmd_state()
	local t = tonumber(readfile(ROLLBACK_DIR .. "/time") or "")
	return { ok = true, rollback = (fs.access(ROLLBACK_DIR .. "/config") and t) and true or false, rollback_time = t }
end

local function cmd_rollback()
	local config = readfile(ROLLBACK_DIR .. "/config")
	if not config or config == "" then
		return { ok = false, error = { code = "no_rollback" } }
	end
	local b = busy()
	if b then return { ok = false, error = { code = "busy", what = b } } end
	local ok, why = install({ config = config, hwid = readfile(ROLLBACK_DIR .. "/hwid"), direct_ip = readfile(ROLLBACK_DIR .. "/direct_ip") })
	if not ok then
		return { ok = false, error = { code = "apply", step = why } }
	end
	call("rm -rf " .. q(ROLLBACK_DIR))
	return { ok = true, service = service_for() }
end

-- ---------------------------------------------------------------- export / import

local function cmd_export(kind)
	local doc = T.export(sections(), kind, { app_version = app_version(), created = os.time() })
	if not doc then return { ok = false, error = { code = "kind" } } end
	if #doc.items == 0 then return { ok = false, error = { code = "empty", kind = kind } } end
	return { ok = true, kind = kind, count = #doc.items, filename = "easy-vless-" .. kind .. "-" .. stamp() .. ".json", content = jsonc.stringify(doc) }
end

local function cmd_import_check(data, kind)
	local doc, size = decode(data)
	local res = T.check_import(doc, sections(), kind, size)
	if res.ok then
		-- the preview needs names, not the entries themselves
		res.names = {}
		for i, o in ipairs(res.add) do
			if i <= 200 then res.names[i] = o.remarks or o.remark or o.address end
		end
		res.count = #res.add
		res.add = nil
	end
	return res
end

local SECTION_TYPE = { nodes = "nodes", rules = "shunt_rules", subscriptions = "subscribe_list" }

local function cmd_import_apply(data, kind)
	local doc, size = decode(data)
	local res = T.check_import(doc, sections(), kind, size)
	if not res.ok then return res end
	if #res.add == 0 then
		return { ok = false, error = { code = "nothing" }, skipped = res.skipped }
	end
	local b = busy()
	if b then return { ok = false, error = { code = "busy", what = b } } end
	call("touch " .. q(SUB_LOCK))
	local ok, e = pcall(function()
		api.uci:revert(CONFIG)
		local router
		for _, o in ipairs(res.add) do
			local target = o.target
			o.target = nil
			local id
			if res.kind == "subscriptions" then
				id = api.uci:add(CONFIG, SECTION_TYPE[res.kind])
			else
				id = api.uci:section(CONFIG, SECTION_TYPE[res.kind], ((res.kind == "rules") and "rule_" or "") .. api.gen_random_char())
			end
			for k, v in pairs(o) do
				api.uci_set_c(id, k, v)
			end
			if target then
				if not router then
					if api.uci_get_c("main_router") == nil then
						api.uci:section(CONFIG, "nodes", "main_router", { remarks = "Main Router", type = "sing-box", protocol = "_shunt", default_node = "_direct" })
					end
					router = true
				end
				api.uci_set_c("main_router", id, target)
			end
		end
		api.uci_save_c(true)
	end)
	call("rm -f " .. q(SUB_LOCK))
	if not ok then
		call("uci -q revert " .. CONFIG)
		return { ok = false, error = { code = "apply", step = tostring(e):sub(1, 200) } }
	end
	return { ok = true, kind = res.kind, added = #res.add, skipped = res.skipped, dropped = res.dropped }
end

-- ---------------------------------------------------------------- main

local input = jsonc.parse(io.read("*a") or "") or {}
local actions = {
	backup = cmd_backup,
	restore_check = function() return cmd_restore_check(input.data) end,
	restore_apply = function() return cmd_restore_apply(input.data) end,
	rollback = cmd_rollback,
	state = cmd_state,
	export = function() return cmd_export(input.kind) end,
	import_check = function() return cmd_import_check(input.data, input.kind) end,
	import_apply = function() return cmd_import_apply(input.data, input.kind) end,
}
local fn = actions[input.action or ""]
local result
if not fn then
	result = { ok = false, error = { code = "action" } }
else
	local ok, res = pcall(fn)
	result = ok and res or { ok = false, error = { code = "internal", detail = tostring(res):sub(1, 300) } }
end
io.write(jsonc.stringify(result) .. "\n")
