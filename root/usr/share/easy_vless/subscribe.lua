#!/usr/bin/lua

------------------------------------------------
-- @author William Chan <root@williamchan.me>
------------------------------------------------
require 'luci.util'
require 'luci.jsonc'
require 'luci.sys'
local api = require "luci.easy_vless.api"
local node_state = require "luci.easy_vless.nodes"
local c_config = api.c_config

local datatypes = api.datatypes
local split = api.split
local base64Decode = api.base64Decode
local jsonParse, jsonStringify = api.jsonc.parse, api.jsonc.stringify
local UrlEncode, UrlDecode = api.UrlEncode, api.UrlDecode
local fs = api.fs
local log = api.log
local i18n = api.i18n
local uci, uci_get, uci_set, uci_del, uci_foreach, uci_save = api.uci, api.uci_get_c, api.uci_set_c, api.uci_del_c, api.uci_foreach_c, api.uci_save_c

-- these global functions are accessed all the time by the event handler
-- so caching them is worth the effort
local tinsert = table.insert
local ssub, slen, schar, sbyte, sformat, sgsub = string.sub, string.len, string.char, string.byte, string.format, string.gsub
local lyaml = require "lyaml"

local has_ss_rust = api.is_finded("sslocal")
local has_ssr = api.is_finded("ssr-local") and api.is_finded("ssr-redir")
local has_singbox = api.finded_com("sing-box")
local has_xray = api.finded_com("xray")
-- Easy VLESS: never silently disable certificate verification for imported
-- TLS nodes. A link without an explicit insecure/allowInsecure parameter keeps
-- verification on unless the user opts in via global_subscribe.allowInsecure.
local DEFAULT_ALLOWINSECURE = (uci_get("@global_subscribe[0]", "allowInsecure") == "1")
local DEFAULT_FILTER_KEYWORD_MODE = uci_get("@global_subscribe[0]", "filter_keyword_mode") or "0"
local DEFAULT_FILTER_KEYWORD_DISCARD_LIST = uci_get("@global_subscribe[0]", "filter_discard_list") or {}
local DEFAULT_FILTER_KEYWORD_KEEP_LIST = uci_get("@global_subscribe[0]", "filter_keep_list") or {}
-- Nodes should be retrieved using the core type (if not set on the node subscription page, the default type will be used automatically).
local DEFAULT_SS_TYPE = api.get_core("ss_type", {{has_ss_rust,"shadowsocks-rust"},{has_singbox,"sing-box"},{has_xray,"xray"}})
local DEFAULT_TROJAN_TYPE = api.get_core("trojan_type", {{has_singbox,"sing-box"},{has_xray,"xray"}})
local DEFAULT_VMESS_TYPE = api.get_core("vmess_type", {{has_xray,"xray"},{has_singbox,"sing-box"}})
local DEFAULT_VLESS_TYPE = api.get_core("vless_type", {{has_xray,"xray"},{has_singbox,"sing-box"}})
local DEFAULT_HYSTERIA2_TYPE = api.get_core("hysteria2_type", {{has_singbox,"sing-box"},{has_xray,"xray"}})
local core_has = {
	["xray"] = has_xray,
	["sing-box"] = has_singbox,
	["shadowsocks-rust"] = has_ss_rust,
}
-- Determine whether to filter node keywords
local function is_filter_keyword(sub_cfg, value)
	local mode = DEFAULT_FILTER_KEYWORD_MODE
	local discard_list = DEFAULT_FILTER_KEYWORD_DISCARD_LIST
	local keep_list = DEFAULT_FILTER_KEYWORD_KEEP_LIST
	if sub_cfg then
		local filter_keyword_mode = sub_cfg.filter_keyword_mode or "5" -- 5 is global
		if filter_keyword_mode == "0" then
			mode = "0"
		elseif filter_keyword_mode == "1" then
			mode = "1"
			discard_list = sub_cfg.filter_discard_list or {}
		elseif filter_keyword_mode == "2" then
			mode = "2"
			keep_list = sub_cfg.filter_keep_list or {}
		elseif filter_keyword_mode == "3" then
			mode = "3"
			keep_list = sub_cfg.filter_keep_list or {}
			discard_list = sub_cfg.filter_discard_list or {}
		elseif filter_keyword_mode == "4" then
			mode = "4"
			keep_list = sub_cfg.filter_keep_list or {}
			discard_list = sub_cfg.filter_discard_list or {}
		end
	end
	if mode == "1" then
		for k,v in ipairs(discard_list) do
			if value:find(v, 1, true) then
				return true
			end
		end
	elseif mode == "2" then
		local result = true
		for k,v in ipairs(keep_list) do
			if value:find(v, 1, true) then
				result = false
			end
		end
		return result
	elseif mode == "3" then
		local result = false
		for k,v in ipairs(discard_list) do
			if value:find(v, 1, true) then
				result = true
			end
		end
		for k,v in ipairs(keep_list) do
			if value:find(v, 1, true) then
				result = false
			end
		end
		return result
	elseif mode == "4" then
		local result = true
		for k,v in ipairs(keep_list) do
			if value:find(v, 1, true) then
				result = false
			end
		end
		for k,v in ipairs(discard_list) do
			if value:find(v, 1, true) then
				result = true
			end
		end
		return result
	end
	return false
end

local nodeResult = {} -- update result
local nodes_table = {}
for k, e in ipairs(api.get_valid_nodes()) do
	if e.node_type == "normal" then
		nodes_table[#nodes_table + 1] = e
	end
end

-- To retrieve the current server's dynamic configurations, you can use `get` and `set`. `get` requires access to the node table.
local CONFIG = {}
do
	if true then
		local szType = "@global[0]"
		local option = "node"
		
		local node_id = uci_get(szType, option)
		CONFIG[#CONFIG + 1] = {
			log = true,
			remarks = i18n.translatef("Node"),
			currentNode = node_id and uci_get(node_id) or nil,
			set = function(o, server)
				uci_set(szType, option, server)
				o.newNodeId = server
			end
		}
	end

	if true then
		local i = 0
		local option = "node"
		uci_foreach("socks", function(t)
			i = i + 1
			local id = t[".name"]
			local node_id = t[option]
			CONFIG[#CONFIG + 1] = {
				log = true,
				id = id,
				remarks = i18n.translatef("Socks node list [%s]", i),
				currentNode = node_id and uci_get(node_id) or nil,
				set = function(o, server)
					if not server or server == "" then
						if #nodes_table > 0 then
							server = nodes_table[1][".name"]
						end
					end
					uci_set(t[".name"], option, server)
					o.newNodeId = server
				end
			}
			if t.autoswitch_backup_node and #t.autoswitch_backup_node > 0 then
				local flag = i18n.translatef("Socks node list [%s]", i) .. " " .. i18n.translatef("Backup node list")
				local currentNodes = {}
				local newNodes = {}
				for k, asb_node_id in ipairs(t.autoswitch_backup_node) do
					if asb_node_id then
						local currentNode = uci_get(asb_node_id) or {}
						if currentNode[".type"] == "nodes" then
							currentNodes[#currentNodes + 1] = {
								log = true,
								remarks = flag .. "[" .. k .. "]",
								currentNode = currentNode,
								set = function(o, server)
									if server and server ~= "nil" then
										table.insert(o.newNodes, server)
									end
								end
							}
						end
					end
				end
				CONFIG[#CONFIG + 1] = {
					remarks = flag,
					currentNodes = currentNodes,
					newNodes = newNodes,
					set = function(o, newNodes)
						if o then
							if not newNodes then newNodes = o.newNodes end
							uci_set(id, "autoswitch_backup_node", newNodes or {})
						end
					end
				}
			end
		end)
	end

	if true then
		local i = 0
		local option = "lbss"
		local function is_ip_port(str)
			if type(str) ~= "string" then return false end
			local ip, port = str:match("^([%d%.]+):(%d+)$")
			return ip and datatypes.ipaddr(ip) and tonumber(port) and tonumber(port) <= 65535
		end
		uci_foreach("haproxy_config", function(t)
			i = i + 1
			local node_id = t[option]
			CONFIG[#CONFIG + 1] = {
				log = true,
				id = t[".name"],
				remarks = i18n.translatef("HAProxy node list [%s]", i),
				currentNode = node_id and uci_get(node_id) or nil,
				set = function(o, server)
					-- Modify the LBS value only if it is not in IP:Port format.
					if not is_ip_port(t[option]) then
						uci_set(t[".name"], option, server)
						o.newNodeId = server
					end
				end,
				delete = function(o)
					-- Deletion is only performed if the current LBS value is not in IP:port format.
					if not is_ip_port(t[option]) then
						uci_del(t[".name"])
					end
				end
			}
		end)
	end

	if true then
		local i = 0
		uci_foreach("acl_rule", function(t)
			i = i + 1
			local option = "node"
			local node_id = t[option]
			CONFIG[#CONFIG + 1] = {
				log = true,
				id = t[".name"],
				remarks = i18n.translatef("ACL list [%s]", i),
				currentNode = node_id and uci_get(node_id) or nil,
				set = function(o, server)
					uci_set(t[".name"], option, server)
					o.newNodeId = server
				end
			}
		end)
	end

	uci_foreach("nodes", function(node)
		local node_id = node[".name"]
		if node.protocol and node.protocol == '_shunt' then
			local rules = {}
			uci_foreach("shunt_rules", function(e)
				if e[".name"] and e.remarks then
					table.insert(rules, e)
					table.insert(rules, {
						[".name"] = e[".name"] .. "_proxy_tag",
						remarks = e.remarks .. " " .. i18n.translate("Preproxy")
					})
				end
			end)
			table.insert(rules, {
				[".name"] = "default_node",
				remarks = i18n.translatef("Default")
			})
			table.insert(rules, {
				[".name"] = "default_proxy_tag",
				remarks = i18n.translatef("Default") .. " " .. i18n.translate("Preproxy")
			})

			for k, e in pairs(rules) do
				local _node_id = node[e[".name"]] or nil
				if _node_id then
					local section = uci_get(_node_id) or {}
					if section[".type"] == "nodes" then
						CONFIG[#CONFIG + 1] = {
							log = false,
							currentNode = section,
							remarks = i18n.translatef("Shunt [%s] node", e.remarks),
							set = function(o, server)
								if not server then server = "" end
								uci_set(node_id, e[".name"], server)
								o.newNodeId = server
							end
						}
					end
				end
			end
		elseif node.protocol and node.protocol == '_balancing' then
			local flag = i18n.translatef("Xray Load Balancing node [%s] list", node_id)
			local currentNodes = {}
			local newNodes = {}
			if node.balancing_node then
				for k, b_node_id in pairs(node.balancing_node) do
					currentNodes[#currentNodes + 1] = {
						log = true,
						node = b_node_id,
						currentNode = (function()
							local section = uci_get(b_node_id) or {}
							if section[".type"] == "socks" then
								return { Socks = b_node_id }
							end
							return section
						end)(),
						remarks = b_node_id,
						set = function(o, server)
							if o and server and server ~= "nil" then
								table.insert(o.newNodes, server)
							end
						end
					}
				end
			end
			CONFIG[#CONFIG + 1] = {
				remarks = flag,
				currentNodes = currentNodes,
				newNodes = newNodes,
				set = function(o, newNodes)
					if o then
						if not newNodes then newNodes = o.newNodes end
						uci_set(node_id, "balancing_node", newNodes or {})
					end
				end
			}

			-- Backup Node
			local currentNode = uci_get(node_id) or nil
			if currentNode and currentNode.fallback_node then
				local section = uci_get(currentNode.fallback_node) or {}
				if section[".type"] == "nodes" then
					CONFIG[#CONFIG + 1] = {
						log = true,
						id = node_id,
						remarks = i18n.translatef("Xray Load Balancing node [%s] backup node", node_id),
						currentNode = section,
						set = function(o, server)
							uci_set(node_id, "fallback_node", server)
							o.newNodeId = server
						end,
						delete = function(o)
							uci_del(node_id, "fallback_node")
						end
					}
				end
			end
		elseif node.protocol and node.protocol == '_urltest' then
			local flag = i18n.translatef("Sing-Box URLTest node [%s] list", node_id)
			local currentNodes = {}
			local newNodes = {}
			if node.urltest_node then
				for k, u_node_id in pairs(node.urltest_node) do
					currentNodes[#currentNodes + 1] = {
						log = true,
						node = u_node_id,
						currentNode = (function()
							local section = uci_get(u_node_id) or {}
							if section[".type"] == "socks" then
								return { Socks = u_node_id }
							end
							return section
						end)(),
						remarks = u_node_id,
						set = function(o, server)
							if o and server and server ~= "nil" then
								table.insert(o.newNodes, server)
							end
						end
					}
				end
			end
			CONFIG[#CONFIG + 1] = {
				remarks = flag,
				currentNodes = currentNodes,
				newNodes = newNodes,
				set = function(o, newNodes)
					if o then
						if not newNodes then newNodes = o.newNodes end
						uci_set(node_id, "urltest_node", newNodes or {})
					end
				end
			}
		else
			-- Preproxy Node
			local currentNode = uci_get(node_id) or nil
			if currentNode and currentNode.preproxy_node then
				local section = uci_get(currentNode.preproxy_node) or {}
				if section[".type"] == "nodes" then
					CONFIG[#CONFIG + 1] = {
						log = true,
						id = node_id,
						remarks = i18n.translatef("Node [%s] preproxy node", node_id),
						currentNode = uci_get(currentNode.preproxy_node) or nil,
						set = function(o, server)
							uci_set(node_id, "preproxy_node", server)
							o.newNodeId = server
						end,
						delete = function(o)
							uci_del(node_id, "preproxy_node")
						end
					}
				end
			end
			-- Landing node
			local currentNode = uci_get(node_id) or nil
			if currentNode and currentNode.to_node then
				local section = uci_get(currentNode.to_node) or {}
				if section[".type"] == "nodes" then
					CONFIG[#CONFIG + 1] = {
						log = true,
						id = node_id,
						remarks = i18n.translatef("Node [%s] landing node", node_id),
						currentNode = uci_get(currentNode.to_node) or nil,
						set = function(o, server)
							uci_set(node_id, "to_node", server)
							o.newNodeId = server
						end,
						delete = function(o)
							uci_del(node_id, "to_node")
						end
					}
				end
			end
		end
	end)

	for k, v in pairs(CONFIG) do
		if v.currentNodes and type(v.currentNodes) == "table" then
			for kk, vv in pairs(v.currentNodes) do
				if vv.currentNode == nil then
					CONFIG[k].currentNodes[kk] = nil
				end
			end
		else
			if v.currentNode == nil then
				if v.delete then
					v.delete()
				end
				CONFIG[k] = nil
			end
		end
	end
end

-- Retrieve subscribe information (remaining data allowance, expiration time).
local subscribe_info = {}
local function get_subscribe_info(cfgid, value)
	if type(cfgid) ~= "string" or cfgid == "" or type(value) ~= "string" then
		return
	end
	value = value:gsub("%s+", "")
	local date_patterns = {"套餐到期：(.+)", "过期时间：(.+)", "有效期至：(.+)", "到期时间：(.+)", "截止日期：(.+)"}
	local expired_date
	for _, p in ipairs(date_patterns) do expired_date = value:match(p) or expired_date end
	local rem_patterns = {"剩余流量：(.+)", "流量剩余：(.+)", "可用流量：(.+)", "套餐剩余：(.+)"}
	local rem_traffic
	for _, p in ipairs(rem_patterns) do rem_traffic = value:match(p) or rem_traffic end
	subscribe_info[cfgid] = subscribe_info[cfgid] or {expired_date = "", rem_traffic = ""}
	if expired_date then
		subscribe_info[cfgid]["expired_date"] = expired_date
	end
	if rem_traffic then
		subscribe_info[cfgid]["rem_traffic"] = rem_traffic
	end
end

local function parseClashNode(node, add_mode, group, sub_cfg)
	local sub_allowinsecure = DEFAULT_ALLOWINSECURE
	local sub_ss_type = DEFAULT_SS_TYPE
	local sub_trojan_type = DEFAULT_TROJAN_TYPE
	local sub_vmess_type = DEFAULT_VMESS_TYPE
	local sub_vless_type = DEFAULT_VLESS_TYPE
	local sub_hysteria2_type = DEFAULT_HYSTERIA2_TYPE
	local sub_hy_up_mbps, sub_hy_down_mbps
	if sub_cfg then
		if sub_cfg.allowInsecure and sub_cfg.allowInsecure ~= "1" then
			sub_allowinsecure = nil
		end
		local ss_type = sub_cfg.ss_type or "global"
		if ss_type ~= "global" and core_has[ss_type] then
			sub_ss_type = ss_type
		end
		local trojan_type = sub_cfg.trojan_type or "global"
		if trojan_type ~= "global" and core_has[trojan_type] then
			sub_trojan_type = trojan_type
		end
		local vmess_type = sub_cfg.vmess_type or "global"
		if vmess_type ~= "global" and core_has[vmess_type] then
			sub_vmess_type = vmess_type
		end
		local vless_type = sub_cfg.vless_type or "global"
		if vless_type ~= "global" and core_has[vless_type] then
			sub_vless_type = vless_type
		end
		local hysteria2_type = sub_cfg.hysteria2_type or "global"
		if hysteria2_type ~= "global" and core_has[hysteria2_type] then
			sub_hysteria2_type = hysteria2_type
		end
		sub_hy_up_mbps = sub_cfg.hysteria_up_mbps
		sub_hy_down_mbps = sub_cfg.hysteria_down_mbps
	end
	local result = {
		timeout = 60,
		add_mode = add_mode, -- `0` for manual configuration, `1` for import, `2` for subscription
		group = group
	}
	result.remarks = node.name
	result.address = node.server
	result.port = node.port

	if node.type == 'vless' then
		if sub_vless_type == "sing-box" and has_singbox then
			result.type = 'sing-box'
		elseif sub_vless_type == "xray" and has_xray then
			result.type = "Xray"
		else
			log(2, i18n.translatef("Skipping the %s node is due to incompatibility with the %s core program or incorrect node usage type settings.", "VLESS", "VLESS"))
			return nil
		end
		result.protocol = "vless"
		result.uuid = node.uuid
		result.tcp_fast_open = node.tfo
		result.encryption = node.cipher or "none"
		result.flow = node.flow
		result.tls = "0"
		if node.tls then
			result.tls = "1"
			result.tls_serverName = node.servername or ""
			local insecure = node["skip-cert-verify"]
			result.tls_allowInsecure = insecure and "1" or "0"
			if sub_allowinsecure then
				result.tls_allowInsecure = "1"
			end
		end
		if node.tls and node["reality-opts"] and node["reality-opts"]["public-key"] then
			result.reality = "1"
			result.reality_publicKey = (node["reality-opts"] and node["reality-opts"]["public-key"]) or nil
			result.reality_shortId = (node["reality-opts"] and node["reality-opts"]["short-id"]) or nil
		end
		result.transport = node.network and string.lower(node.network) or "tcp"
		if result.type == "sing-box" and result.transport == "raw" then 
			result.transport = "tcp"
		elseif result.type == "Xray" and result.transport == "tcp" then
			result.transport = "raw"
		end
		if result.transport == 'ws' then
			local ws_opts = node["ws-opts"]
			if ws_opts then
				if ws_opts.headers then
					result.ws_host = ws_opts.headers.Host or ws_opts.headers.host
				end
				if ws_opts.path then
					result.ws_path = ws_opts.path
					if ws_opts["max-early-data"] then
						if result.type == "sing-box" then
							result.ws_enableEarlyData = "1"
							result.ws_maxEarlyData = tonumber(ws_opts["max-early-data"])
							result.ws_earlyDataHeaderName = "Sec-WebSocket-Protocol"
						elseif result.type == "Xray" then
							result.ws_path = result.ws_path .. "?ed=" .. ws_opts["max-early-data"]
						end
					end
				end
			end
		end
	end
	if not result.remarks or result.remarks == "" then
		if result.address and result.port then
			result.remarks = result.address .. ':' .. result.port
		else
			result.remarks = "NULL"
		end
	end
	return result
end

-- Processing Clash data
local function processClashData(content, add_mode, group, sub_cfg)
	local results = {}
	for i, node in ipairs(content.proxies or {}) do
		local result = parseClashNode(node, add_mode, group, sub_cfg)
		if result then
			table.insert(results, result)
		end
	end
	return results
end

-- sing-box JSON subscriptions (Easy VLESS): the subscription is used only as a
-- source of proxy server definitions. Only outbounds[] (and endpoints[] for the
-- skip report) are read; inbounds, dns, route (final/rules/rule_set and their
-- foreign file paths), log, experimental (Clash API) are never used.
local SINGBOX_NON_PROXY = { direct = true, block = true, dns = true, selector = true, urltest = true }

local function singbox_str(v)
	if v == nil then return nil end
	if type(v) == "table" then
		local t = {}
		for _, x in ipairs(v) do t[#t + 1] = tostring(x) end
		return (#t > 0) and table.concat(t, ",") or nil
	end
	v = tostring(v)
	return (v ~= "") and v or nil
end

local function parseSingBoxOutbound(ob, index, add_mode, group, sub_cfg)
	local result = {
		timeout = 60,
		add_mode = add_mode, -- `0` for manual configuration, `1` for import, `2` for subscription
		group = group
	}
	local vless_type = sub_cfg and sub_cfg.vless_type or "global"
	if vless_type == "xray" and has_xray then
		result.type = "Xray"
	elseif has_singbox then
		result.type = "sing-box"
	elseif has_xray then
		result.type = "Xray"
	else
		log(2, i18n.translatef("Skipping the %s node is due to incompatibility with the %s core program or incorrect node usage type settings.", "VLESS", "VLESS"))
		return nil
	end
	result.protocol = "vless"
	result.remarks = singbox_str(ob.tag) or ("VLESS " .. index)
	result.address = singbox_str(ob.server)
	result.port = singbox_str(ob.server_port)
	result.uuid = singbox_str(ob.uuid)
	result.encryption = "none"
	result.flow = singbox_str(ob.flow)

	local tls = type(ob.tls) == "table" and ob.tls or {}
	result.tls = "0"
	if tls.enabled == true then
		result.tls = "1"
		result.tls_serverName = singbox_str(tls.server_name)
		result.alpn = singbox_str(tls.alpn)
		if tls.insecure == true then
			result.tls_allowInsecure = "1"
		else
			result.tls_allowInsecure = (sub_cfg and sub_cfg.allowInsecure == "1") and "1" or "0"
		end
		local utls = type(tls.utls) == "table" and tls.utls or {}
		if utls.enabled == true then
			result.utls = "1"
			result.fingerprint = singbox_str(utls.fingerprint) or "chrome"
		end
		local reality = type(tls.reality) == "table" and tls.reality or {}
		if reality.enabled == true then
			result.reality = "1"
			result.reality_publicKey = singbox_str(reality.public_key)
			result.reality_shortId = singbox_str(reality.short_id)
		end
		local ech = type(tls.ech) == "table" and tls.ech or {}
		if ech.enabled == true and type(ech.config) == "table" and #ech.config > 0 then
			result.ech = "1"
			result.ech_config = table.concat(ech.config, "\\n")
		end
	end

	local tr = type(ob.transport) == "table" and ob.transport or {}
	local ttype = singbox_str(tr.type) or "tcp"
	if ttype == "ws" then
		result.transport = "ws"
		result.ws_path = singbox_str(tr.path)
		local h = type(tr.headers) == "table" and tr.headers or {}
		result.ws_host = singbox_str(h.Host or h.host)
		if tonumber(tr.max_early_data) and tonumber(tr.max_early_data) > 0 then
			if result.type == "sing-box" then
				result.ws_enableEarlyData = "1"
				result.ws_maxEarlyData = tonumber(tr.max_early_data)
				result.ws_earlyDataHeaderName = singbox_str(tr.early_data_header_name) or "Sec-WebSocket-Protocol"
			else
				result.ws_path = (result.ws_path or "/") .. "?ed=" .. tonumber(tr.max_early_data)
			end
		end
	elseif ttype == "grpc" then
		result.transport = "grpc"
		result.grpc_serviceName = singbox_str(tr.service_name)
		result.grpc_mode = "gun"
	elseif ttype == "httpupgrade" then
		result.transport = "httpupgrade"
		result.httpupgrade_host = singbox_str(tr.host)
		result.httpupgrade_path = singbox_str(tr.path)
	elseif ttype == "http" then
		if result.type == "sing-box" then
			result.transport = "http"
			local host = tr.host
			if type(host) == "string" then host = { host } end
			result.http_host = (type(host) == "table" and #host > 0) and host or nil
			result.http_path = singbox_str(tr.path)
		else
			result.transport = "xhttp"
			result.xhttp_mode = "stream-one"
			result.xhttp_host = type(tr.host) == "table" and singbox_str(tr.host[1]) or singbox_str(tr.host)
			result.xhttp_path = singbox_str(tr.path)
		end
	elseif ttype == "tcp" then
		result.transport = (result.type == "Xray") and "raw" or "tcp"
		result.tcp_guise = "none"
	else
		log(2, i18n.translatef("Skip node: %s. Because Sing-Box does not support the %s protocol's %s transmission method, Xray needs to be used instead.", result.remarks, "vless", ttype))
		return nil
	end
	if not (result.address and result.port and result.uuid) then
		result.error_msg = "server / server_port / uuid missing"
	end
	return result
end

-- Returns nodes (parsed VLESS outbounds) and a report table.
local function processSingBoxData(conf, add_mode, group, sub_cfg)
	local results = {}
	local report = { found = 0, skipped = 0, skipped_types = {}, ignored = 0 }
	local function skip(t)
		report.skipped = report.skipped + 1
		report.skipped_types[t] = (report.skipped_types[t] or 0) + 1
	end
	local vless_index = 0
	for _, ob in ipairs(conf.outbounds or {}) do
		local t = type(ob) == "table" and singbox_str(ob.type) or nil
		if t == "vless" then
			vless_index = vless_index + 1
			report.found = report.found + 1
			local ok, r = pcall(parseSingBoxOutbound, ob, vless_index, add_mode, group, sub_cfg)
			if ok and r then
				results[#results + 1] = r
			else
				skip("vless (invalid)")
			end
		elseif t and SINGBOX_NON_PROXY[t] then
			report.ignored = report.ignored + 1
		else
			skip(t or "unknown")
		end
	end
	for _, ep in ipairs(type(conf.endpoints) == "table" and conf.endpoints or {}) do
		skip(((type(ep) == "table" and singbox_str(ep.type)) or "unknown") .. " (endpoint)")
	end
	return results, report
end

-- Detect the subscription body format. Returns "singbox", <table> for a
-- sing-box JSON config (object with an outbounds array, an array of such
-- objects, or an array of outbound objects); "json_invalid" for text that
-- looks like JSON but does not parse / has no outbounds; nil otherwise.
local function detect_json(raw)
	local text = raw
	if not text:match("^%s*[%{%[]") then
		-- base64-wrapped JSON (only for bodies that are pure base64 text)
		if not raw:match("^[%w%+/=_%-%s]+$") then return nil end
		local ok, dec = pcall(base64Decode, raw)
		if ok and type(dec) == "string" and dec ~= raw and dec:match("^%s*[%{%[]") then
			text = dec
		else
			return nil
		end
	end
	local ok, data = pcall(jsonParse, text)
	if not ok or type(data) ~= "table" then
		return "json_invalid", "the JSON document does not parse"
	end
	if type(data.outbounds) == "table" then
		return "singbox", { outbounds = data.outbounds, endpoints = data.endpoints }
	end
	if #data > 0 then
		local merged = { outbounds = {}, endpoints = {} }
		for _, item in ipairs(data) do
			if type(item) == "table" and type(item.outbounds) == "table" then
				for _, o in ipairs(item.outbounds) do merged.outbounds[#merged.outbounds + 1] = o end
				for _, e in ipairs(type(item.endpoints) == "table" and item.endpoints or {}) do merged.endpoints[#merged.endpoints + 1] = e end
			elseif type(item) == "table" and item.type then
				merged.outbounds[#merged.outbounds + 1] = item
			end
		end
		if #merged.outbounds > 0 or #merged.endpoints > 0 then
			return "singbox", merged
		end
	end
	return "json_invalid", "JSON without an \"outbounds\" array (not a sing-box configuration)"
end

-- Processing data
local function processData(szType, content, add_mode, group, sub_cfg)
	--log(2, content, add_mode, group)
	local sub_allowinsecure = DEFAULT_ALLOWINSECURE
	local sub_ss_type = DEFAULT_SS_TYPE
	local sub_trojan_type = DEFAULT_TROJAN_TYPE
	local sub_vmess_type = DEFAULT_VMESS_TYPE
	local sub_vless_type = DEFAULT_VLESS_TYPE
	local sub_hysteria2_type = DEFAULT_HYSTERIA2_TYPE
	local sub_hy_up_mbps, sub_hy_down_mbps
	if sub_cfg then
		if sub_cfg.allowInsecure and sub_cfg.allowInsecure ~= "1" then
			sub_allowinsecure = nil
		end
		local ss_type = sub_cfg.ss_type or "global"
		if ss_type ~= "global" and core_has[ss_type] then
			sub_ss_type = ss_type
		end
		local trojan_type = sub_cfg.trojan_type or "global"
		if trojan_type ~= "global" and core_has[trojan_type] then
			sub_trojan_type = trojan_type
		end
		local vmess_type = sub_cfg.vmess_type or "global"
		if vmess_type ~= "global" and core_has[vmess_type] then
			sub_vmess_type = vmess_type
		end
		local vless_type = sub_cfg.vless_type or "global"
		if vless_type ~= "global" and core_has[vless_type] then
			sub_vless_type = vless_type
		end
		local hysteria2_type = sub_cfg.hysteria2_type or "global"
		if hysteria2_type ~= "global" and core_has[hysteria2_type] then
			sub_hysteria2_type = hysteria2_type
		end
		sub_hy_up_mbps = sub_cfg.hysteria_up_mbps
		sub_hy_down_mbps = sub_cfg.hysteria_down_mbps
	end
	local result = {
		timeout = 60,
		add_mode = add_mode, -- `0` for manual configuration, `1` for import, `2` for subscription
		group = group
	}
	if szType == "vless" then
		if sub_vless_type == "sing-box" and has_singbox then
			result.type = 'sing-box'
		elseif sub_vless_type == "xray" and has_xray then
			result.type = "Xray"
		else
			log(2, i18n.translatef("Skipping the %s node is due to incompatibility with the %s core program or incorrect node usage type settings.", "VLESS", "VLESS"))
			return nil
		end
		result.protocol = "vless"
		local alias = ""
		if content:find("#") then
			local idx_sp = content:find("#")
			alias = content:sub(idx_sp + 1, -1)
			content = content:sub(0, idx_sp - 1)
		end
		result.remarks = UrlDecode(alias)
		if content:find("@") then
			local Info = split(content, "@")
			result.uuid = UrlDecode(Info[1])
			local port = "443"
			Info[2] = (Info[2] or ""):gsub("/%?", "?")
			local query = split(Info[2], "%?")
			local host_port = query[1]
			local params = {}
			for _, v in pairs(split(query[2], '&')) do
				local s = v:find("=", 1, true)
				if s and s > 1 then
					params[v:sub(1, s - 1)] = UrlDecode(v:sub(s + 1))
				end
			end
			-- [2001:4860:4860::8888]:443
			-- 8.8.8.8:443
			if host_port:find(":") then
				local sp = split(host_port, ":")
				port = sp[#sp]
				if api.is_ipv6addrport(host_port) then
					result.address = api.get_ipv6_only(host_port)
				else
					result.address = sp[1]
				end
			else
				result.address = host_port
			end

			if not params.type then params.type = "tcp" end
			params.type = string.lower(params.type)
			if ({ xhttp=true, kcp=true, mkcp=true })[params.type] and result.type ~= "Xray" and has_xray then
				result.type = "Xray"
			end
			if result.type == "sing-box" and params.type == "raw" then 
				params.type = "tcp"
			elseif result.type == "Xray" and params.type == "tcp" then
				params.type = "raw"
			end
			if params.type == "h2" or params.type == "http" then
				params.type = "http"
				result.transport = (result.type == "Xray") and "xhttp" or "http"
			else
				result.transport = params.type
			end
			if params.type == 'ws' then
				result.ws_host = params.host
				result.ws_path = params.path
				if result.type == "sing-box" and params.path then
					local ws_path_dat = split(params.path, "%?")
					local ws_path = ws_path_dat[1]
					local ws_path_params = {}
					for _, v in pairs(split(ws_path_dat[2], '&')) do
						local t = split(v, '=')
						ws_path_params[t[1]] = t[2]
					end
					if ws_path_params.ed and tonumber(ws_path_params.ed) then
						result.ws_path = ws_path
						result.ws_enableEarlyData = "1"
						result.ws_maxEarlyData = tonumber(ws_path_params.ed)
						result.ws_earlyDataHeaderName = "Sec-WebSocket-Protocol"
					end
				end
			end
			if params.type == "http" then
				if result.type == "sing-box" then
					result.transport = "http"
					result.http_host = (params.host and params.host ~= "") and { params.host } or nil
					result.http_path = params.path
				elseif result.type == "Xray" then
					result.transport = "xhttp"
					result.xhttp_mode = "stream-one"
					result.xhttp_host = params.host
					result.xhttp_path = params.path
				end
			end
			if params.type == 'raw' or params.type == 'tcp' then
				result.tcp_guise = params.headerType or "none"
				result.tcp_guise_http_host = (params.host and params.host ~= "") and { params.host } or nil
				result.tcp_guise_http_path = (params.path and params.path ~= "") and { params.path } or nil
			end
			if params.type == 'kcp' or params.type == 'mkcp' then
				result.transport = "mkcp"
				result.mkcp_guise = params.headerType or "none"
				result.mkcp_seed = params.seed
			end
			if params.type == 'quic' then
				result.quic_guise = params.headerType or "none"
				result.quic_key = params.key
				result.quic_security = params.quicSecurity or "none"
			end
			if params.type == 'grpc' then
				if params.path then result.grpc_serviceName = params.path end
				if params.serviceName then result.grpc_serviceName = params.serviceName end
				result.grpc_mode = params.mode or "gun"
			end
			if params.type == 'xhttp' or params.type == 'splithttp' then
				result.xhttp_host = params.host
				result.xhttp_path = params.path
				result.xhttp_mode = params.mode or "auto"
				result.use_xhttp_extra = (params.extra and params.extra ~= "") and "1" or nil
				result.xhttp_extra = (params.extra and params.extra ~= "") and api.base64Encode(params.extra) or nil
				local success, Data = pcall(jsonParse, params.extra)
				if success and Data then
					local address = (Data.extra and Data.extra.downloadSettings and Data.extra.downloadSettings.address)
							or (Data.downloadSettings and Data.downloadSettings.address)
					result.download_address = (address and address ~= "") and address:gsub("^%[", ""):gsub("%]$", "") or nil
				end
			end
			if params.type == 'httpupgrade' then
				result.httpupgrade_host = params.host
				result.httpupgrade_path = params.path
			end
			result.encryption = params.encryption or "none"
			result.flow = params.flow

			if (not params.security or params.security == "") and params.flow then
				params.security = "tls"
			end

			result.tls = "0"
			if params.security == "tls" or params.security == "reality" then
				result.tls = "1"
				result.tls_serverName = (params.sni and params.sni ~= "") and params.sni or params.host
				result.alpn = params.alpn
				if params.fp and params.fp ~= "" then
					result.utls = "1"
					result.fingerprint = params.fp
				end
				if params.ech and params.ech ~= "" then
					result.ech = "1"
					result.ech_config = params.ech
				end
				result.tls_pinSHA256 = params.pcs
				result.tls_CertByName = params.vcn
				if params.security == "reality" then
					result.reality = "1"
					result.reality_publicKey = params.pbk or nil
					result.reality_shortId = params.sid or nil
					result.reality_spiderX = params.spx or nil
					result.use_mldsa65Verify = (params.pqv and params.pqv ~= "") and "1" or nil
					result.reality_mldsa65Verify = params.pqv or nil
				end
				local insecure = params.allowinsecure or params.allowInsecure or params.insecure
				result.tls_allowInsecure = (insecure == "1" or insecure == "0") and insecure or (sub_allowinsecure and "1" or "0")
			end

			result.port = port
			result.tcp_fast_open = params.tfo
			result.use_finalmask = (params.fm and params.fm ~= "") and "1" or nil
			result.finalmask = (params.fm and params.fm ~= "") and api.base64Encode(params.fm) or nil

			if result.type == "sing-box" and (result.transport == "mkcp" or result.transport == "xhttp") then
				log(2, i18n.translatef("Skip node: %s. Because Sing-Box does not support the %s protocol's %s transmission method, Xray needs to be used instead.", result.remarks, szType, result.transport))
				return nil
			end
		end
	else
		log(2, i18n.translatef("%s type node subscriptions are not currently supported, skip this node.", szType))
		return nil
	end
	if not result.remarks or result.remarks == "" then
		if result.address and result.port then
			result.remarks = result.address .. ':' .. result.port
		else
			result.remarks = "NULL"
		end
	end
	return result
end

local function curl(url, file, ua, mode, hwid)
	if not url or url == "" then return 22, 404 end
	-- Easy VLESS: the server certificate is always verified (no -k): a
	-- subscription decides which servers carry all traffic and may include the
	-- router's HWID, so it must not be accepted from an unauthenticated peer.
	local curl_args = {
		"-fsL", "-w %{http_code}", "--retry 3", "--connect-timeout 3", "-H 'Accept: */*'", "-H 'Accept-Encoding: identity'"
	}
	if ua and ua ~= "" and ua ~= "curl" then
		ua = (ua == "easy_vless") and ("easy_vless/" .. api.get_version()) or ua
		curl_args[#curl_args + 1] = "--user-agent " .. api.shellquote(ua)
	end
	if hwid == "1" then
		curl_args[#curl_args + 1] = get_headers()
	end
	local return_code, result
	if mode == "direct" then
		return_code, result = api.curl_direct(url, file, curl_args)
	elseif mode == "proxy" then
		return_code, result = api.curl_proxy(url, file, curl_args)
	else
		return_code, result = api.curl_auto(url, file, curl_args)
	end
	return return_code, tonumber(result)
end

-- HWID (Easy VLESS): one stable identifier per router, generated once and
-- persisted in /etc/easy_vless/hwid (flash; listed in the package conffiles),
-- reused across reboots, restarts and updates. Provider-agnostic: sent as
-- the X-HWID request header (plus the usual X-Device-* headers) only for
-- subscriptions with "HWID Support" (subscribe_list.hwid = 1).
local HWID_FILE = "/etc/easy_vless/hwid"

local function readfile(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local c = f:read("*a")
	f:close()
	return api.trim(c)
end

local function sha256(text)
	local p = io.popen("printf '%s' '" .. text:gsub("'", "'\\''") .. "' | sha256sum")
	if not p then return nil end
	local hash = p:read("*l")
	p:close()
	return hash and hash:match("^(%x+)")
end

function get_hwid()
	local hwid = readfile(HWID_FILE)
	if hwid and hwid:match("^[%w%-]+$") and #hwid >= 16 and #hwid <= 128 then
		return hwid
	end
	-- first use: derive from the router identity when available (the same
	-- value survives a factory reset), otherwise from a random UUID
	local model = readfile("/tmp/sysinfo/model")
	local mac = readfile("/sys/class/net/eth0/address")
	local seed
	if mac and mac:match("^%x%x:") and mac ~= "00:00:00:00:00:00" and model and model ~= "" then
		seed = mac .. "-" .. model
	else
		seed = readfile("/proc/sys/kernel/random/uuid") or tostring(os.time()) .. tostring(math.random())
	end
	hwid = sha256(seed)
	if not hwid then return nil end
	luci.sys.call("mkdir -p /etc/easy_vless")
	local tmp = HWID_FILE .. ".tmp"
	local f = io.open(tmp, "w")
	if f then
		f:write(hwid .. "\n")
		f:close()
		os.rename(tmp, HWID_FILE)
	end
	return hwid
end

function get_headers()
	local headers = {}
	headers[#headers + 1] = "X-Device-OS: OpenWrt"
	local rel = readfile("/etc/openwrt_release")
	local os_ver = rel and rel:match("DISTRIB_RELEASE='([^']+)'")
	if os_ver then
		headers[#headers + 1] = "X-Ver-OS: " .. os_ver
	end
	local model = readfile("/tmp/sysinfo/model")
	if model then
		headers[#headers + 1] = "X-Device-Model: " .. model
	end
	local hwid = get_hwid()
	if hwid then
		headers[#headers + 1] = "X-HWID: " .. hwid
	else
		log(1, i18n.translatef("HWID could not be generated; the subscription is requested without X-HWID."))
	end
	local out = {}
	for i = 1, #headers do
		out[i] = "-H '" .. headers[i]:gsub("'", "'\\''") .. "'"
	end
	return table.concat(out, " ")
end

local function truncate_nodes(group)
	for _, config in pairs(CONFIG) do
		if config.currentNodes and #config.currentNodes > 0 then
			local newNodes = {}
			local removeNodesSet = {}
			for k, v in pairs(config.currentNodes) do
				if v.currentNode and v.currentNode.add_mode == "2" then
					if (not group) or (group:lower() == (v.currentNode.group or ""):lower()) then
						removeNodesSet[v.currentNode[".name"]] = true
					end
				end
			end
			for _, value in ipairs(config.currentNodes) do
				if not removeNodesSet[value.currentNode[".name"]] then
					newNodes[#newNodes + 1] = value.currentNode[".name"]
				end
			end
			if config.set then
				config.set(config, newNodes)
			end
		else
			if config.currentNode and config.currentNode.add_mode == "2" then
				if (not group) or (group:lower() == (config.currentNode.group or ""):lower()) then
					if config.delete then
						config.delete(config)
					elseif config.set then
						config.set(config, "")
					end
				end
			end
		end
	end
	uci_foreach("nodes", function(node)
		if node.add_mode == "2" then
			if (not group) or (group:lower() == (node.group or ""):lower()) then
				uci_del(node['.name'])
			end
		end
	end)
	uci_foreach("subscribe_list", function(o)
		if (not group) or (group:lower() == (o.remark or ""):lower()) then
			uci_del(o['.name'], "md5")
		end
	end)
	uci_save(true)
end

local function select_node(nodes, config, parentConfig)
	local log_level = 1
	if parentConfig then
		log_level = log_level + 1
	end
	if config.currentNode then
		local server
		-- Load balancing, keeping the original ID of the Socks [port] node in urltest.
		if config.currentNode["Socks"] then
			server = config.currentNode.Socks
		end
		-- Special priority: cfgid
		if config.currentNode[".name"] then
			for index, node in pairs(nodes) do
				if node[".name"] == config.currentNode[".name"] then
					if config.log == nil or config.log == true then
						log(log_level, i18n.translatef("Update [%s]", config.remarks) .. " " .. i18n.translatef("Matching node:") .. " " .. node.remarks)
					end
					server = node[".name"]
					break
				end
			end
		end
		-- First priority: Type + Notes + IP + Port + Group
		if not server then
			for index, node in pairs(nodes) do
				if config.currentNode.type and config.currentNode.remarks and config.currentNode.address and config.currentNode.port then
					if node.type and node.remarks and node.address and node.port then
						if node.type == config.currentNode.type and node.remarks == config.currentNode.remarks and (node.address .. ':' .. node.port == config.currentNode.address .. ':' .. config.currentNode.port) and node.group == config.currentNode.group then
							if config.log == nil or config.log == true then
								log(log_level, i18n.translatef("Update [%s]", config.remarks) .. " " .. i18n.translatef("First Matching node:") .. " " .. node.remarks)
							end
							server = node[".name"]
							break
						end
					end
				end
			end
		end
		-- Second priority: Type + IP + Port + Group
		if not server then
			for index, node in pairs(nodes) do
				if config.currentNode.type and config.currentNode.address and config.currentNode.port then
					if node.type and node.address and node.port then
						if node.type == config.currentNode.type and (node.address .. ':' .. node.port == config.currentNode.address .. ':' .. config.currentNode.port) and node.group == config.currentNode.group then
							if config.log == nil or config.log == true then
								log(log_level, i18n.translatef("Update [%s]", config.remarks) .. " " .. i18n.translatef("Second Matching node:") .. " " .. node.remarks)
							end
							server = node[".name"]
							break
						end
					end
				end
			end
		end
		-- Third priority: IP + Port + Group
		if not server then
			for index, node in pairs(nodes) do
				if config.currentNode.address and config.currentNode.port then
					if node.address and node.port then
						if node.address .. ':' .. node.port == config.currentNode.address .. ':' .. config.currentNode.port and node.group == config.currentNode.group then
							if config.log == nil or config.log == true then
								log(log_level, i18n.translatef("Update [%s]", config.remarks) .. " " .. i18n.translatef("Third Matching node:") .. " " .. node.remarks)
							end
							server = node[".name"]
							break
						end
					end
				end
			end
		end
		-- Fourth priority: IP + Group
		if not server then
			for index, node in pairs(nodes) do
				if config.currentNode.address then
					if node.address then
						if node.address == config.currentNode.address and node.group == config.currentNode.group then
							if config.log == nil or config.log == true then
								log(log_level, i18n.translatef("Update [%s]", config.remarks) .. " " .. i18n.translatef("Fourth Matching node:") .. " " .. node.remarks)
							end
							server = node[".name"]
							break
						end
					end
				end
			end
		end
		-- Fifth priority: remarks + Group
		if not server then
			for index, node in pairs(nodes) do
				if config.currentNode.remarks then
					if node.remarks then
						if node.remarks == config.currentNode.remarks and node.group == config.currentNode.group then
							if config.log == nil or config.log == true then
								log(log_level, i18n.translatef("Update [%s]", config.remarks) .. " " .. i18n.translatef("Fifth Matching node:") .. " " .. node.remarks)
							end
							server = node[".name"]
							break
						end
					end
				end
			end
		end
		if not parentConfig then
			-- If that doesn't work, just find one.
			if not server then
				if #nodes_table > 0 then
					if config.log == nil or config.log == true then
						log(log_level, i18n.translatef("Update [%s]", config.remarks) .. " " .. i18n.translatef("Unable to find the best matching node, now replaced with:") .. " " .. nodes_table[1].remarks)
					end
					server = nodes_table[1][".name"]
				end
			end
		end
		if server then
			if parentConfig then
				config.set(parentConfig, server)
			else
				config.set(config, server)
			end
		end
	else
		if not parentConfig then
			config.set(config, "")
		end
	end
end

-- Easy VLESS 0.9.0: what an update did to the nodes of a subscription
-- (cfgid -> { new, updated, unchanged, removed, excluded }), see nodes.lua.
local sub_stats = {}

local function update_node(manual)
	if next(nodeResult) == nil then
		log(1, i18n.translatef("No node information updates are available."))
		return
	end

	local group = {}
	for _, v in ipairs(nodeResult) do
		group[v["remark"]:lower()] = true
	end

	-- the nodes of the updated subscriptions before the update, by group
	local existing = {}
	if manual == 0 and next(group) then
		uci_foreach("nodes", function(node)
			-- Do not delete nodes if no new nodes are found or nodes were manually imported...
			if node.add_mode == "2" and (node.group and group[node.group:lower()] == true) then
				local g = node.group:lower()
				existing[g] = existing[g] or {}
				table.insert(existing[g], node)
				uci_del(node['.name'])
			end
		end)
	end
	for _, v in ipairs(nodeResult) do
		local remark = v["remark"]
		local list = v["list"]
		local sub_cfg = v["sub_cfg"]
		-- Easy VLESS 0.9.0 (nodes.lua): a node the user deleted is not
		-- imported again; a node that was already there keeps its section id
		-- (matched by identity, not by its position or name), so the main
		-- node, rule targets and URL Test groups keep pointing to it.
		local keep_ids = {}
		if manual == 0 and sub_cfg then
			local excluded, stats
			list, excluded = node_state.filter_excluded(list, sub_cfg.excluded_node)
			keep_ids, stats = node_state.merge(existing[remark:lower()], list)
			existing[remark:lower()] = nil
			stats.excluded = excluded
			if sub_cfg[".name"] then sub_stats[sub_cfg[".name"]] = stats end
			if excluded > 0 then
				log(1, i18n.translatef("[%s] %s node(s) deleted by the user were not imported again.", remark, excluded))
			end
		end
		local domain_resolver, domain_resolver_dns, domain_resolver_dns_https, domain_strategy
		local preproxy_node_group, to_node_group, outbound_iface_group, chain_node_type = "", "", "", ""
		-- Subscription Group Chain Agent
		local function valid_chain_node(node)
			if not node then return "" end
			local cp = uci_get(node, "chain_proxy") or ""
			local am = uci_get(node, "add_mode") or "0"
			chain_node_type = (cp == "" and am ~= "2") and (uci_get(node, "type") or "") or ""
			if chain_node_type ~= "Xray" and chain_node_type ~= "sing-box" then
				chain_node_type = ""
				return ""
			end
			return node
		end
		if sub_cfg then
			domain_resolver = sub_cfg.domain_resolver
			domain_resolver_dns = sub_cfg.domain_resolver_dns
			domain_resolver_dns_https = sub_cfg.domain_resolver_dns_https
			domain_strategy = (sub_cfg.domain_strategy == "UseIPv4" or sub_cfg.domain_strategy == "UseIPv6") and sub_cfg.domain_strategy or nil
			preproxy_node_group = (sub_cfg.chain_proxy == "1") and valid_chain_node(sub_cfg.preproxy_node) or ""
			to_node_group = (sub_cfg.chain_proxy == "2") and valid_chain_node(sub_cfg.to_node) or ""
			outbound_iface_group = (sub_cfg.chain_proxy == "3") and sub_cfg.outbound_iface or ""
			chain_node_type = (outbound_iface_group ~= "") and "iface" or chain_node_type
		end
		for i, vv in ipairs(list) do
			local cfgid = uci:section(c_config, "nodes", keep_ids[i] or api.gen_random_char())
			for kkk, vvv in pairs(vv) do
				if type(vvv) == "table" and next(vvv) ~= nil then
					uci_set(cfgid, kkk, vvv)
				else
					if kkk ~= "group" or vvv ~= "default" then
						uci_set(cfgid, kkk, vvv)
					end
					-- Sing-Box Node Domain resolver
					if kkk == "type" and (vvv == "Xray" or vvv == "sing-box") then
						if domain_resolver then
							uci_set(cfgid, "domain_resolver", domain_resolver)
							if domain_resolver_dns then
								uci_set(cfgid, "domain_resolver_dns", domain_resolver_dns)
							elseif domain_resolver_dns_https then
								uci_set(cfgid, "domain_resolver_dns_https", domain_resolver_dns_https)
							end
						end
						if domain_strategy then
							if vvv == "sing-box" then
								domain_strategy = (domain_strategy == "UseIPv4" and "ipv4_only") or (domain_strategy == "UseIPv6" and "ipv6_only") or domain_strategy
							end
							uci_set(cfgid, "domain_strategy", domain_strategy)
						end
					end
					-- Subscription Group Chain Agent
					if chain_node_type ~= "" and kkk == "type" and (vvv == "Xray" or vvv == "sing-box") then
						if preproxy_node_group ~="" then
							uci_set(cfgid, "chain_proxy", "1")
							uci_set(cfgid, "preproxy_node", preproxy_node_group)
						elseif to_node_group ~= "" then
							uci_set(cfgid, "chain_proxy", "2")
							uci_set(cfgid, "to_node", to_node_group)
						elseif outbound_iface_group ~= "" then
							uci_set(cfgid, "chain_proxy", "3")
							uci_set(cfgid, "outbound_iface", outbound_iface_group)
						end
					end		
				end
			end
		end
	end
	-- Update subscription information
	for cfgid, info in pairs(subscribe_info) do
		for key, value in pairs(info) do
			if value ~= "" then
				uci_set(cfgid, key, value)
			else
				uci_del(cfgid, key)
			end
		end
	end

	if next(CONFIG) then
		local nodes = {}
		uci_foreach("nodes", function(node)
			nodes[#nodes + 1] = node
		end)

		for _, config in pairs(CONFIG) do
			if config.currentNodes and #config.currentNodes > 0 then
				if config.remarks and config.currentNodes[1].log ~= false then
					log(1, i18n.translatef("Update [%s]", config.remarks))
				end
				for kk, vv in pairs(config.currentNodes) do
					select_node(nodes, vv, config)
				end
				config.set(config)
				if not config.newNodes or #config.newNodes == 0 then
					log(1, i18n.translatef("[%s]", config.remarks) .. " " .. i18n.translate("Unable to find a new node. Please confirm and process manually."))
				end
			else
				select_node(nodes, config)
			end
		end
	end

	uci_save(true)

	if arg[3] == "cron" then
		if not fs.access(api.LOCK_PREFIX .. ".lock") then
			luci.sys.call("touch %s_cron.lock" % api.LOCK_PREFIX)
		end
	end

	if manual ~= 1 then
		luci.sys.call("/etc/init.d/easy_vless restart > /dev/null 2>&1 &")
	end
end

-- Returns (Easy VLESS) the number of accepted nodes and the detected format.
local function parse_link(raw, add_mode, group, sub_cfg)
	local format_label
	if raw and #raw > 0 then
		local cfgid
		if sub_cfg then
			cfgid = sub_cfg[".name"]
		end
		local nodes, szType, clashTable, singboxConf, singboxReport
		local node_list = {}
		-- Easy VLESS: JSON first (JSON is also valid YAML and would otherwise
		-- be taken for a Clash document): sing-box JSON -> outbounds.
		local json_kind, json_data = detect_json(raw)
		local yamlTable = (json_kind == nil) and lyaml.load(raw) or nil
		if json_kind == "singbox" then
			szType = "singbox"
			singboxConf = json_data
			nodes = {}
			format_label = "sing-box JSON"
			log(2, i18n.translatef("Subscription format: %s", "sing-box JSON"))
		elseif json_kind == "json_invalid" then
			szType = "json_invalid"
			nodes = {}
			format_label = "invalid JSON"
			log(1, i18n.translatef("Subscription [%s]: invalid sing-box JSON (%s); existing nodes are kept.", group, json_data))
		elseif yamlTable and type(yamlTable) == "table" then
			-- clash
			szType = "clash"
			clashTable = yamlTable
			format_label = "Clash YAML"
			log(2, i18n.translatef("Subscription format: %s", "Clash YAML"))
		else
			-- Base64 or plain-text URI list
			if add_mode == "1" then
				nodes = split(raw, "\n")
			else
				format_label = raw:find("://", 1, true) and "URL list" or "base64 URL list"
				log(2, i18n.translatef("Subscription format: %s", format_label))
				nodes = split(base64Decode(raw):gsub("\r\n", "\n"), "\n")
			end
		end

		function nodeFilter(node)
			if node then
				-- Easy VLESS 1.0: a subscription is untrusted text. Control
				-- characters (a line break in a name) never reach UCI, and the
				-- port has to be a port.
				for k, v in pairs(node) do
					if type(v) == "string" then
						node[k] = v:gsub("%c", "")
					elseif type(v) == "table" then
						for i, x in ipairs(v) do
							if type(x) == "string" then v[i] = x:gsub("%c", "") end
						end
					end
				end
				-- a name is shown in LuCI, where some places insert HTML: no tags
				if type(node.remarks) == "string" then
					node.remarks = node.remarks:gsub("[<>]", "")
				end
				if type(node.remarks) == "string" and #node.remarks > 200 then
					-- cut at a character boundary (UTF-8)
					node.remarks = node.remarks:sub(1, 200):gsub("[\192-\255][\128-\191]*$", "")
				end
				local port = tonumber(node.port)
				if not node.error_msg and node.address and not (port and port >= 1 and port <= 65535 and port == math.floor(port)) then
					node.error_msg = "invalid port " .. tostring(node.port):sub(1, 20)
				end
				if node.error_msg then
					log(2, i18n.translatef("Discard node: %s, Reason:", node.remarks) .. " " .. node.error_msg)
				elseif not node.type then
					log(2, i18n.translatef("Discard node: %s, Reason:", node.remarks) .. " " .. i18n.translatef("No usable binary was found."))
				elseif (add_mode == "2" and is_filter_keyword(sub_cfg, node.remarks)) or not node.address or node.remarks == "NULL" or node.address == "127.0.0.1" or
						(not datatypes.hostname(node.address) and not (api.is_ip(node.address))) then
					log(2, i18n.translatef("Discard filter nodes: %s type node %s", node.type, node.remarks))
				else
					tinsert(node_list, node)
				end
				if add_mode == "2" then
					get_subscribe_info(cfgid, node.remarks)
				end
			end
		end

		if szType == "singbox" and singboxConf then
			local sbNodes
			sbNodes, singboxReport = processSingBoxData(singboxConf, add_mode, group, sub_cfg)
			for _, v in ipairs(sbNodes) do
				nodeFilter(v)
			end
		end

		if szType == "clash" and clashTable then
			nodes = {}
			local clashNodes = processClashData(clashTable, add_mode, group, sub_cfg)
			for _, v in ipairs(clashNodes) do
				nodeFilter(v)
			end
		end

		for _, v in ipairs(nodes) do
			if v and not string.match(v, "^%s*$") then
				xpcall(function ()
					local result
					if not szType then
						local node = api.trim(v)
						local dat = split(node, "://")
						if dat and dat[1] and dat[2] then
							local link = dat[2]:gsub("&amp;", "&"):gsub("%s*#%s*", "#")  -- Some odd links use "&" as "&", and include spaces before and after "#".
							result = processData(dat[1], link, add_mode, group, sub_cfg)
						end
					else
						log(2, i18n.translatef("Skip unknown types:") .. " " .. szType)
					end
					-- log(2, result)
					nodeFilter(result)
				end, function (err)
					--log(2, err)
					log(2, v, i18n.translatef("Parsing error, skip this node."))
				end
			)
			end
		end
		if #node_list > 0 then
			nodeResult[#nodeResult + 1] = {
				remark = group,
				list = node_list,
				sub_cfg = sub_cfg
			}
		end
		if singboxReport then
			local types = {}
			for t, n in pairs(singboxReport.skipped_types) do types[#types + 1] = (n > 1) and (t .. " x" .. n) or t end
			table.sort(types)
			local skipped = singboxReport.skipped + (singboxReport.found - #node_list - (singboxReport.skipped_types["vless (invalid)"] or 0))
			log(1, i18n.translatef("[%s] sing-box JSON: imported %s, skipped %s%s", group, #node_list, skipped,
				(#types > 0) and ("; skipped types: " .. table.concat(types, ", ")) or ""))
			if #node_list == 0 then
				log(1, i18n.translatef("[%s] No supported VLESS outbound was found in the sing-box JSON; existing nodes are kept.", group))
			end
		end
		log(2, i18n.translatef("Successfully resolved the [%s] node, number: %s", group, #node_list))
		return #node_list, format_label
	else
		if add_mode == "2" then
			log(2, i18n.translatef("Get subscription content for [%s] is empty. This may be due to an invalid subscription address or a network problem. Please diagnose the issue!", group))
		end
	end
	return 0, format_label
end

-- Easy VLESS 0.8.0: the result of the last update of every subscription for
-- LuCI (rpcd "subscribe state"), in tmpfs: /var/run/easy_vless_sub/<id>.json
--   time, status (ok | unchanged | no_nodes | empty | download | tls |
--   skipped | error), found (supported nodes in the downloaded list),
--   before / after (nodes of this subscription in the node list), format,
--   http_code, curl_code, request (the User-Agent that answered: curl, HAPP
--   or custom), fallback (Auto: the HAPP request was needed).
local SUB_STATE_DIR = "/var/run/" .. c_config .. "_sub"
local sub_records = {}

local function group_count(remark)
	local n = 0
	remark = (remark or ""):lower()
	uci_foreach("nodes", function(node)
		if node.add_mode == "2" and node.group and node.group:lower() == remark then
			n = n + 1
		end
	end)
	return n
end

local function write_sub_records()
	if next(sub_records) == nil then return end
	luci.sys.call("mkdir -p " .. SUB_STATE_DIR)
	for cfgid, rec in pairs(sub_records) do
		if rec.after == nil then
			rec.after = group_count(rec.remark)
		end
		-- 0.9.0: new / updated / unchanged / removed / excluded (see update_node)
		for k, n in pairs(sub_stats[cfgid] or {}) do
			rec[k] = n
		end
		rec.status = rec.status or "error"
		local path = SUB_STATE_DIR .. "/" .. cfgid .. ".json"
		local f = io.open(path .. ".tmp", "w")
		if f then
			f:write(jsonStringify(rec))
			f:close()
			os.rename(path .. ".tmp", path)
		end
	end
end

local execute = function()
	do
		local subscribe_list = {}
		local fail_list = {}
		if arg[2] ~= "all" then
			string.gsub(arg[2], '[^' .. "," .. ']+', function(w)
				subscribe_list[#subscribe_list + 1] = uci_get(w) or {}
			end)
		else
			uci_foreach("subscribe_list", function(o)
				subscribe_list[#subscribe_list + 1] = o
			end)
		end

		local manual_sub = arg[3] == "manual"
		local cron_sub = arg[3] == "cron"
		local function service_running()
			local pid = readfile("/var/run/" .. c_config .. ".pid")
			return pid and pid:match("^%d+$") and fs.access("/proc/" .. pid) and true or false
		end

		for index, value in ipairs(subscribe_list) do
			local cfgid = value[".name"]
			local remark = value.remark or ""
			local url = value.url or ""
			local rec = { time = os.time(), remark = remark, before = group_count(remark), found = 0 }
			if cfgid then sub_records[cfgid] = rec end
			-- "Update only when connected": automatic updates are skipped while
			-- Easy VLESS is not running (the Update button always runs).
			if cron_sub and value.update_connected == "1" and not service_running() then
				log(1, i18n.translatef("[%s] Automatic update skipped: Easy VLESS is not connected (not running).", remark))
				url = nil
				rec.status = "skipped"
			end
			if url then

			local url_is_local
			-- Request strategy (User-Agent option user_agent):
			--   unset / "curl"  curl's own User-Agent (as before 0.8.0)
			--   "HAPP"          User-Agent: HAPP
			--   other text      that User-Agent
			--   "auto" (0.8.0)  curl first; only when that answer is an HTTP
			--                   4xx error or has no supported node, one more
			--                   request as HAPP - never more than two requests
			-- X-HWID / X-Device-* headers are sent in every request when HWID
			-- Support is on (hwid = 1).
			local ua_opt = value.user_agent
			local auto = (ua_opt == "auto")
			local function fetch(ua)
				local access_mode = value.access_mode
				local result = (not access_mode) and i18n.translatef("Auto") or (access_mode == "direct" and i18n.translatef("Direct") or (access_mode == "proxy" and i18n.translatef("Proxy") or i18n.translatef("Auto")))
				log(1, i18n.translatef("Start subscribing: %s", '【' .. remark .. '】' .. url .. ' [' .. result .. ']'))
				tmp_file = "/tmp/" .. cfgid
				local return_code
				return_code, value.http_code = curl(url, tmp_file, ua, access_mode, value.hwid)
				rec.curl_code = return_code
				rec.http_code = value.http_code
				rec.request = (not ua or ua == "" or ua == "curl") and "curl" or ((ua == "HAPP") and "HAPP" or "custom")
				if return_code ~= 0 then
					luci.sys.call("rm -f " .. api.shellquote(tmp_file))
					-- curl 35/51/60/77: TLS handshake / certificate / CA store
					if return_code == 35 or return_code == 51 or return_code == 60 or return_code == 77 then
						rec.status = "tls"
						log(1, i18n.translatef("[%s] The TLS certificate of the subscription server could not be verified (curl error %s). Check the router time (date) and the CA certificates (package ca-bundle).", remark, tostring(return_code)))
					else
						rec.status = "download"
					end
				end
				return return_code
			end
			-- the downloaded list: parse it (unless unchanged); false = no file
			local function process()
				if not fs.access(tmp_file) then
					return false
				end
				local ok = true
				if luci.sys.call("[ -f " .. api.shellquote(tmp_file) .. " ] && sed -i -e '/^[ \t]*$/d' -e '/^[ \t]*\r$/d' " .. api.shellquote(tmp_file)) == 0 then
					local f = io.open(tmp_file, "r")
					local stdout = f:read("*all")
					f:close()
					local raw_data = api.trim(stdout)
					local old_md5 = value.md5 or ""
					local new_md5 = luci.sys.exec("md5sum " .. api.shellquote(tmp_file) .. " 2>/dev/null | awk '{print $1}'"):gsub("\n", "")
					if not manual_sub and old_md5 == new_md5 then
						log(1, i18n.translatef("Subscription: [%s] No changes, no update required.", remark))
						rec.status = "unchanged"
					else
						rec.found, rec.format = parse_link(raw_data, "2", remark, value)
						if rec.found > 0 then
							rec.status = "ok"
							uci_set(cfgid, "md5", new_md5)
							uci_set(cfgid, "update_time", tostring(os.time()))
						else
							rec.status = (raw_data == "") and "empty" or "no_nodes"
						end
					end
				else
					ok = false
				end
				if url_is_local then
					value.http_code = 0
				else
					luci.sys.call("rm -f " .. api.shellquote(tmp_file))
				end
				return ok
			end
			if fs.access(url) then
				-- debug, reads local files.
				log(1, i18n.translatef("Start subscribing: %s", '【' .. remark .. '】' .. url))
				url_is_local = true
				tmp_file = url
				if not process() then fail_list[#fail_list + 1] = value end
			else
				-- Auto: the first request with curl's own User-Agent
				local rc = fetch((not auto) and ua_opt or nil)
				local processed = (rc == 0) and process()
				local http = tonumber(value.http_code) or 0
				if auto and ((rc == 22 and http >= 400 and http < 500) or (processed and rec.status ~= "ok" and rec.status ~= "unchanged")) then
					log(1, i18n.translatef("[%s] No supported node with the default request (%s); requesting once more as HAPP (User-Agent: HAPP).", remark,
						(rc ~= 0) and ("HTTP " .. tostring(value.http_code)) or tostring(rec.status)))
					rec.fallback = true
					rc = fetch("HAPP")
					processed = (rc == 0) and process()
				end
				if rc ~= 0 or not processed then
					if rc == 0 then rec.status = "error" end
					fail_list[#fail_list + 1] = value
				end
			end
			end
		end

		if #fail_list > 0 then
			for index, value in ipairs(fail_list) do
				log(1, i18n.translatef("[%s] Subscription failed. This could be due to an invalid subscription address or a network issue. Please diagnose the problem! [%s]", value.remark, tostring(value.http_code)))
			end
		end
		update_node(0)
	end
end

-- Easy VLESS 0.9.0: node list actions of LuCI (rpcd "nodes"). They run here
-- because they change the same node list as an update and therefore share
-- its lock (check_instance). The decisions are made by nodes.lua; the answer
-- is one JSON object on stdout.
--   delete <id>          delete one server; a subscription node is remembered
--                        in subscribe_list.excluded_node (not imported again)
--   delete_all_plan      what "Delete all nodes" would do (nothing is changed)
--   delete_all           delete every server, repair what pointed to them
--   restore <sub> [key]  forget one / all deleted nodes of a subscription
local function all_sections()
	local t = {}
	for _, stype in ipairs({ "global", "nodes", "shunt_rules", "subscribe_list" }) do
		uci_foreach(stype, function(s) t[#t + 1] = s end)
	end
	return t
end

local function apply_plan(plan)
	for _, id in ipairs(plan.remove or {}) do
		uci_del(id)
	end
	for _, v in ipairs(plan.set or {}) do
		if type(v[3]) == "table" and #v[3] == 0 then
			uci_del(v[1], v[2])
		else
			uci_set(v[1], v[2], v[3])
		end
	end
	for _, v in ipairs(plan.del or {}) do
		uci_del(v[1], v[2])
	end
	uci_save(true)
end

local function node_action(action, a1, a2)
	local sections = all_sections()
	if action == "delete" then
		local plan, err, refs = node_state.plan_delete(sections, a1 or "")
		if not plan then
			return { ok = false, error = err, references = refs }
		end
		apply_plan(plan)
		return { ok = true, removed = 1, excluded = plan.excluded }
	elseif action == "delete_all_plan" or action == "delete_all" then
		local plan = node_state.plan_delete_all(sections)
		local res = { ok = true, counts = plan.counts, changes = plan.changes, stop = plan.stop, removed = plan.remove }
		if action == "delete_all" and #plan.remove > 0 then
			apply_plan(plan)
			local bad = node_state.dangling(all_sections())
			if #bad > 0 then
				res.ok = false
				res.error = "dangling"
				res.dangling = bad
			end
		end
		return res
	elseif action == "restore" then
		local sub = uci_get(a1 or "")
		if type(sub) ~= "table" or sub[".type"] ~= "subscribe_list" then
			return { ok = false, error = "unknown" }
		end
		local key = (a2 and a2 ~= "") and a2 or nil
		local list, n = node_state.restore(sub.excluded_node, key)
		if n > 0 then
			-- an unchanged subscription is imported again on the next update
			apply_plan({ set = { { a1, "excluded_node", list } }, del = { { a1, "md5" } } })
		end
		return { ok = true, restored = n }
	end
	return { ok = false, error = "action" }
end

-- The lock of everything that rewrites the node list (an update, an import,
-- the node list actions of LuCI, backup.lua's import). Easy VLESS 1.0: the
-- file holds the PID of its owner. A lock whose owner is gone - the process
-- was killed, or ended with an error - is stale and is taken over, instead
-- of answering "busy" until the next reboot.
local SUB_LOCK = api.LOCK_PREFIX .. "_subscribe.lock"

local function lock_stale()
	local pid = readfile(SUB_LOCK)
	return pid ~= nil and pid:match("^%d+$") ~= nil and not fs.access("/proc/" .. pid)
end

local function check_instance(action)
	local rule_lock = api.LOCK_PREFIX .. "_rule_update.lock"

	if action == "start" then
		math.randomseed(os.time() + math.floor(os.clock() * 1000))
		api.nixio.nanosleep(0, math.random(100, 1000) * 1000000)
		if fs.access(SUB_LOCK) and not lock_stale() then
			log(0, i18n.translatef("[Subscription] instance is running; please try again later.") .. "\n")
			os.exit(0)
		else
			local f = io.open(SUB_LOCK, "w")
			if f then
				f:write(tostring(api.nixio.getpid()) .. "\n")
				f:close()
			end
			uci:revert(c_config)
		end
	elseif action == "end" then
		os.remove(SUB_LOCK)
		return
	end

	if fs.access(rule_lock) then
		log(0, i18n.translatef("[Rule Update] instance is running; [Subscription] queue and wait.") .. "\n")
	end
	while fs.access(rule_lock) do
		api.nixio.nanosleep(2, 0)
	end
end

if arg[1] then
	check_instance("start")

	-- whatever happens below, the lock is released (check_instance "end")
	local ok, err = xpcall(function()
		if arg[1] == "start" then
			log(0, i18n.translatef("Start subscribing..."))
			xpcall(execute, function(e)
				log(1, e)
				log(1, debug.traceback())
				log(1, i18n.translatef("Error, restoring service."))
			end)
			write_sub_records()
			log(0, i18n.translatef("Subscription complete...") .. "\n")
		elseif arg[1] == "add" then
			local f = assert(io.open("/tmp/links.conf", 'r'))
			local raw = f:read('*all')
			f:close()
			parse_link(raw, "1", arg[2])
			update_node(1)
			os.remove("/tmp/links.conf")
		elseif arg[1] == "truncate" then
			truncate_nodes(arg[2])
		elseif arg[1] == "delete" or arg[1] == "delete_all" or arg[1] == "delete_all_plan" or arg[1] == "restore" then
			local ok, res = pcall(node_action, arg[1], arg[2], arg[3])
			if not ok then
				log(1, tostring(res))
				res = { ok = false, error = "internal", detail = tostring(res) }
			end
			io.write(jsonStringify(res) .. "\n")
		end
	end, function(e)
		return tostring(e) .. "\n" .. debug.traceback()
	end)

	check_instance("end")
	if not ok then
		log(1, tostring(err))
		-- changes that were not committed do not stay behind for the next run
		pcall(function() uci:revert(c_config) end)
		os.exit(1)
	end
end
