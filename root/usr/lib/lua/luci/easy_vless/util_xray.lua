-- Easy VLESS
-- Reduced fork of PassWall2's util_xray.lua (PassWall2 25.5.15-1, commit 394f384).
-- Client-only, VLESS-focused: server-mode, foreign protocols (vmess/trojan/
-- shadowsocks/wireguard/hysteria/hysteria2) and Xray's own "_balancing"/
-- observatory AUTO mechanism have been removed. AUTO grouping is provided
-- solely by sing-box's urltest mechanism (see util_sing-box.lua).
module("luci.easy_vless.util_xray", package.seeall)
local api = require "luci.easy_vless.api"
local sys = api.sys
local jsonc = api.jsonc
local fs = api.fs
local CACHE_PATH = api.CACHE_PATH

local GLOBAL = {
	DNS_SERVER = {},
	DNS_HOSTNAME = {}
}

local xray_version = api.get_app_version("xray")

local xray_min_version = "26.7.11"

local function get_domain_excluded()
	local path = "/usr/share/easy_vless/domains_excluded"
	local content = fs.readfile(path)
	if not content then return nil end
	local hosts = {}
	string.gsub(content, '[^' .. "\n" .. ']+', function(w)
		local s = api.trim(w)
		if s == "" then return end
		if s:find("#") and s:find("#") == 1 then return end
		if not s:find("#") or s:find("#") ~= 1 then table.insert(hosts, s) end
	end)
	if #hosts == 0 then hosts = nil end
	return hosts
end

local function get_log_level(s)
	if s == "warn" then s = "warning" end
	return s
end

--[[
local cipherSuites = {
	"TLS_AES_128_GCM_SHA256", "TLS_AES_256_GCM_SHA384", "TLS_CHACHA20_POLY1305_SHA256",
	"TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA", "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA",
	"TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA", "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA",
	"TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256", "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
	"TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256", "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
	"TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256", "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
}
local cipherSuites_lookup = {}
for i, v in ipairs(cipherSuites) do
	cipherSuites_lookup[v] = true
end
]]--

function gen_outbound(flag, node, tag, proxy_table)
	local result = nil
	if node then
		local node_id = node[".name"]
		if tag == nil then
			tag = node_id
		end
		local remarks = node.remarks

		local proxy_tag, dialer_proxy_tag, fragment, noise
		if proxy_table ~= nil and type(proxy_table) == "table" then
			proxy_tag = proxy_table.tag or nil
			fragment = proxy_table.fragment and true or nil
			noise = proxy_table.noise and true or nil
		end

		if node.type ~= "Xray" then
			local new_port
			local run_socks_instance = true
			if NO_RUN then
				TMP_PORT = TMP_PORT and TMP_PORT + 1 or 3001
				new_port = TMP_PORT
				run_socks_instance = nil
			else
				local relay_port = (proxy_tag and node.port) and tostring(node.port) or ""
				if relay_port == "" then
					local cache = api.get_socks_port_by_cache(node_id)
					if cache then
						new_port = cache
						run_socks_instance = nil
					end
				end
				if run_socks_instance then
					new_port = api.get_new_port()
					local config_file = string.format("nodesocks_%s_%s.json", node_id, new_port)
					if tag and node_id and not tag:find(node_id) then
						config_file = string.format("nodesocks_%s_%s_%s.json", tag, node_id, new_port)
					end
					sys.call(string.format('/usr/share/easy_vless/app.sh run_socks "%s"> /dev/null',
						string.format("flag=%s node=%s bind=%s socks_port=%s config_file=%s relay_port=%s",
							new_port, --flag
							node_id, --node
							"127.0.0.1", --bind
							new_port, --socks port
							config_file, --config file
							relay_port --relay port
							)
						)
					)
					if relay_port == "" then
						api.set_socks_port_to_cache(node_id, new_port)
					end
				end
			end
			if new_port then
				node = {}
				node.protocol = "socks"
				node.transport = "raw"
				node.address = "127.0.0.1"
				node.port = new_port
				node.stream_security = "none"
				proxy_tag = "socks <- " .. node_id
			end
		else
			dialer_proxy_tag = proxy_tag
		end
		
		if node.type == "Xray" then
			if node.tls and node.tls == "1" then
				node.stream_security = "tls"
				if node.reality and node.reality == "1" then
					node.stream_security = "reality"
				end
			end
		end

		if node.protocol == "http" and node.stream_security == "tls" then
			node.transport = "raw"
		end

		if remarks then
			tag = tag .. ":" .. remarks
		end

		node.address = (node.address or ""):lower()

		result = {
			_id = node_id,
			_flag = flag,
			_flag_proxy_tag = proxy_tag,
			tag = tag,
			protocol = node.protocol,
			mux = {
				enabled = (node.mux == "1") and true or false,
				concurrency = (node.mux == "1" and ((node.mux_concurrency) and tonumber(node.mux_concurrency) or -1)) or nil,
				xudpConcurrency = (node.mux == "1" and ((node.xudp_concurrency) and tonumber(node.xudp_concurrency) or 8)) or nil
			} or nil,
			streamSettings = (node.streamSettings or dialer_proxy_tag or node.protocol == "vless" or node.protocol == "socks" or node.protocol == "http") and {
				sockopt = {
					mark = 255,
					domainStrategy = node.domain_strategy or "UseIP",
					tcpFastOpen = (node.tcp_fast_open == "1") and true or nil,
					tcpMptcp = (node.tcpMptcp == "1") and true or nil,
					happyEyeballs = (node.happy_eyeballs == "1") and {
						TryDelayMs = 250,
						PrioritizeIPv6 = false,
						Interleave = 1,
						MaxConcurrentTry = 4
					} or nil,
					dialerProxy = dialer_proxy_tag,
				},
				method = node.transport,
				security = node.stream_security,
				tlsSettings = (node.stream_security == "tls") and {
					serverName = node.tls_serverName,
					fingerprint = (node.type == "Xray" and node.utls == "1" and node.fingerprint and node.fingerprint ~= "") and node.fingerprint or nil,
					pinnedPeerCertSha256 = node.tls_pinSHA256 or "",
					verifyPeerCertByName = node.tls_CertByName or "",
					echConfigList = (node.ech == "1") and node.ech_config or nil,
					certificates = (node.tls_certificate == "1" and node.tls_certificate_pem ~= "") and {
						certificate = api.split(node.tls_certificate_pem:gsub("\\n", "\n"), "\n"),
						usage = "verify"
					} or nil,
					cipherSuites = (node.cipherSuites and #node.cipherSuites > 0) and table.concat(node.cipherSuites, ":") or nil,
				} or nil,
				realitySettings = (node.stream_security == "reality") and {
					serverName = node.tls_serverName,
					publicKey = node.reality_publicKey,
					shortId = node.reality_shortId or "",
					spiderX = node.reality_spiderX or "/",
					fingerprint = (node.type == "Xray" and node.fingerprint and node.fingerprint ~= "") and node.fingerprint or "chrome",
					mldsa65Verify = (node.use_mldsa65Verify == "1") and node.reality_mldsa65Verify or nil
				} or nil,
				rawSettings = ((node.transport == "raw" or node.transport == "tcp") and node.protocol ~= "socks" and (node.tcp_guise and node.tcp_guise ~= "none")) and {
					header = {
						type = node.tcp_guise,
						request = (node.tcp_guise == "http") and {
							path = node.tcp_guise_http_path and (function()
									local t, r = node.tcp_guise_http_path, {}
									for _, v in ipairs(t) do
										r[#r + 1] = (v == "" and "/" or v)
									end
									return r
								end)() or {"/"},
							headers = (node.tcp_guise_http_host or node.user_agent) and {
								Host = node.tcp_guise_http_host,
								["User-Agent"] = node.user_agent and {node.user_agent} or nil
							} or nil
						} or nil
					}
				} or nil,
				kcpSettings = (node.transport == "mkcp") and {
					mtu = (node.mkcp_mtu and node.mkcp_mtu ~= "") and tonumber(node.mkcp_mtu) or 1350,
					tti = 50,
					uplinkCapacity = 12,
					downlinkCapacity = 100,
					cwndMultiplier = 1,
					maxSendingWindow = 2 * 1024 * 1024
				} or nil,
				wsSettings = (node.transport == "ws") and {
					path = node.ws_path or "/",
					host = node.ws_host,
					headers = node.user_agent and {
						["User-Agent"] = node.user_agent
					} or nil,
					maxEarlyData = tonumber(node.ws_maxEarlyData) or nil,
					earlyDataHeaderName = (node.ws_earlyDataHeaderName) and node.ws_earlyDataHeaderName or nil,
					heartbeatPeriod = tonumber(node.ws_heartbeatPeriod) or nil
				} or nil,
				grpcSettings = (node.transport == "grpc") and {
					serviceName = node.grpc_serviceName,
					multiMode = (node.grpc_mode == "multi") and true or false,
					idle_timeout = node.grpc_idle_timeout and (tonumber(node.grpc_idle_timeout) < 10 and 10 or tonumber(node.grpc_idle_timeout)) or nil,
					health_check_timeout = tonumber(node.grpc_health_check_timeout) or nil,
					permit_without_stream = (node.grpc_permit_without_stream == "1") and true or false,
					initial_windows_size = node.grpc_initial_windows_size and tonumber(node.grpc_initial_windows_size) or 0,
					user_agent = node.user_agent
				} or nil,
				httpupgradeSettings = (node.transport == "httpupgrade") and {
					path = node.httpupgrade_path or "/",
					host = node.httpupgrade_host,
					headers =  node.user_agent and {
						["User-Agent"] = node.user_agent
					} or nil
				} or nil,
				xhttpSettings = (node.transport == "xhttp") and {
					mode = node.xhttp_mode or "auto",
					path = node.xhttp_path or "/",
					host = node.xhttp_host,
					extra = (function()
						local extra = {}
						if node.xhttp_extra then
							local ok, parsed = pcall(jsonc.parse, api.base64Decode(node.xhttp_extra))
							if ok and type(parsed) == "table" then
								extra = parsed.extra or parsed
							end
						end
						-- Handling User-Agent
						if node.user_agent and node.user_agent ~= "" then
							extra.headers = extra.headers or {}
							if not extra.headers["User-Agent"] and not extra.headers["user-agent"] then
								extra.headers["User-Agent"] = node.user_agent
							end
						end
						return api.cleanEmptyTables(extra)
					end)()
				} or nil,
				finalmask = (function()
					local finalmask = {}
					local TP = node.transport
					if TP == "mkcp" then
						local map = {none = "none", srtp = "srtp", utp = "utp", ["wechat-video"] = "wechat",
							dtls = "dtls", wireguard = "wireguard", dns = "dns"}
						local udp = {}
						if node.mkcp_guise and node.mkcp_guise ~= "none" then
							local g = { type = "mkcp-legacy" }
							g.settings = { header = map[node.mkcp_guise] }
							if node.mkcp_guise == "dns" and node.mkcp_domain and node.mkcp_domain ~= "" then
								g.settings.value = node.mkcp_domain
							end
							udp[#udp+1] = g
						end
						local s = { type = "mkcp-legacy" }
						if node.mkcp_seed and node.mkcp_seed ~= "" then
							s.settings = { value = node.mkcp_seed }
						end
						udp[#udp+1] = s
						finalmask.udp = udp
					end
					if fragment and fragment_table and ({raw=1, ws=1, httpupgrade=1, grpc=1, xhttp=1})[TP] then
						finalmask.tcp = finalmask.tcp or {}
						finalmask.tcp[#finalmask.tcp+1] = api.clone(fragment_table)
					end
					if noise and noise_table and (TP == "mkcp" or (TP == "xhttp" and node.alpn == "h3")) then
						finalmask.udp = finalmask.udp or {}
						finalmask.udp[#finalmask.udp+1] = api.clone(noise_table)
					end
					if node.finalmask and node.finalmask ~= "" then
						local ok, fm = pcall(jsonc.parse, api.base64Decode(node.finalmask))
						if ok and type(fm) == "table" then
							finalmask = fm
						end
					end
					return api.cleanEmptyTables(finalmask)
				end)()
			} or nil,
			settings = {
				address = node.address,
				port = tonumber(node.port),
				id = (node.protocol == "vless") and node.uuid or nil,
				encryption = (node.protocol == "vless") and ((node.encryption and node.encryption ~= "") and node.encryption or "none") or nil,
				flow = (node.protocol == "vless" and (node.tls == "1" or (node.encryption and node.encryption ~= "" and node.encryption ~= "none"))
					and node.flow and node.flow ~= "") and node.flow or nil,
				user = (node.protocol == "socks" or node.protocol == "http") and node.username or nil,
				pass = (node.protocol == "socks" or node.protocol == "http") and node.password or nil,
				level = 0
			}
		}

		local alpn = {}
		if node.alpn and node.alpn ~= "default" then
			string.gsub(node.alpn, '[^' .. "," .. ']+', function(w)
				table.insert(alpn, w)
			end)
		end
		if alpn and #alpn > 0 then
			if result.streamSettings.tlsSettings then
				result.streamSettings.tlsSettings.alpn = alpn
			end
		end

		if api.datatypes.hostname(node.address) and node.domain_resolver and (node.domain_resolver_dns or node.domain_resolver_dns_https) then
			local dns_tag = node_id .. "_dns"
			local dns_proto = node.domain_resolver
			local config_address
			local config_port
			if dns_proto == "https" then
				local _a = api.parseURL(node.domain_resolver_dns_https)
				if _a then
					config_address = node.domain_resolver_dns_https
					if _a.port then
						config_port = _a.port
					else
						config_port = 443
					end
					if _a.hostname then
						if api.datatypes.hostname(_a.hostname) then
							GLOBAL.DNS_HOSTNAME[_a.hostname] = true
						end
					end
				end
			else
				local server_address = node.domain_resolver_dns
				local config_port = 53
				local split = api.split(server_address, ":")
				if #split > 1 then
					server_address = split[1]
					config_port = tonumber(split[#split])
				end
				config_address = server_address
				if dns_proto == "tcp" then
					config_address = dns_proto .. "://" .. server_address .. ":" .. config_port
				end
			end
			GLOBAL.DNS_SERVER[node_id] = {
				tag = dns_tag,
				queryStrategy = node.domain_strategy or "UseIP",
				address = config_address,
				port = config_port,
				domains = {"full:" .. node.address},
				finalQuery = true,
				disableCache = false,
				serveStale = true,
			}
		end

	end
	return result
end

function gen_config(var)
	local flag = var["flag"]
	local loglevel = var["loglevel"] or "warning"
	local node_id = var["node"]
	local server_host = var["server_host"]
	local server_port = var["server_port"]
	local tcp_proxy_way = var["tcp_proxy_way"]
	local redir_port = var["redir_port"]
	local local_socks_address = var["local_socks_address"] or "0.0.0.0"
	local local_socks_port = var["local_socks_port"]
	local local_socks_username = var["local_socks_username"]
	local local_socks_password = var["local_socks_password"]
	local local_http_address = var["local_http_address"] or "0.0.0.0"
	local local_http_port = var["local_http_port"]
	local local_http_username = var["local_http_username"]
	local local_http_password = var["local_http_password"]
	local dns_listen_port = var["dns_listen_port"]
	local direct_dns_udp_server = var["direct_dns_udp_server"]
	local direct_dns_udp_port = var["direct_dns_udp_port"]
	local direct_dns_tcp_server = var["direct_dns_tcp_server"]
	local direct_dns_tcp_port = var["direct_dns_tcp_port"]
	local direct_dns_query_strategy = var["direct_dns_query_strategy"]
	local direct_ipset = var["direct_ipset"]
	local direct_nftset = var["direct_nftset"]
	local remote_dns_udp_server = var["remote_dns_udp_server"]
	local remote_dns_udp_port = var["remote_dns_udp_port"]
	local remote_dns_tcp_server = var["remote_dns_tcp_server"]
	local remote_dns_tcp_port = var["remote_dns_tcp_port"]
	local remote_dns_doh_url = var["remote_dns_doh_url"]
	local remote_dns_doh_host = var["remote_dns_doh_host"]
	local remote_dns_doh_ip = var["remote_dns_doh_ip"]
	local remote_dns_doh_port = var["remote_dns_doh_port"]
	local remote_dns_fake = var["remote_dns_fake"]
	local remote_dns_query_strategy = var["remote_dns_query_strategy"]
	local remote_dns_detour = var["remote_dns_detour"]
	local dns_cache = var["dns_cache"]
	NO_RUN = var["no_run"]

	local dns_domain_rules = {}
	local dns = {}
	local fakedns = nil
	local inbounds = {}
	local outbounds = {}
	local routing = nil
	local observatory = nil
	local burstObservatory = nil
 	local strategy = nil
	local COMMON = {}

	local CACHE_TEXT_FILE = CACHE_PATH .. "/cache_" .. flag .. ".txt"

	local xray_settings = api.uci_get_c("@global_xray[0]") or {}

	if xray_settings.fragment == "1" then
		local lengths, delays = {}, {}
		api.trim(xray_settings.fragment_lengths):gsub("[^,]+", function(w)
			w = w:gsub("%s+", "")
			if w ~= "" then lengths[#lengths+1] = w end
		end)
		api.trim(xray_settings.fragment_delays):gsub("[^,]+", function(w)
			w = w:gsub("%s+", "")
			if w ~= "" then delays[#delays+1] = w end
		end)
		fragment_table = {
			type = "fragment",
			settings = {
				packets = xray_settings.fragment_packets or "tlshello",
				lengths = #lengths > 0 and lengths or {"3-5","6-8","10-20"},
				delays = #delays > 0 and delays or {"10-20"},
				maxSplit = xray_settings.fragment_maxSplit or "3-6"
			}
		}
	end

	if xray_settings.noise == "1" then
		local noises = {}
		api.uci_foreach_c("xray_noise_packets", function(n)
			if n.enabled == "1" then
				local noise = {
					rand = (n.type == "rand" and n.packet) and (n.packet:find("-", 1, true) and n.packet or tonumber(n.packet)) or nil,
					type = (n.type ~= "rand") and n.type or nil,
					packet = (n.type ~= "rand") and n.packet or nil,
					delay = n.delay and (n.delay:find("-", 1, true) and n.delay or tonumber(n.delay)) or nil
				}
				table.insert(noises, noise)
			end
		end)
		noise_table = #noises > 0 and {
			type = "noise",
			settings = { reset = 0, noise = noises }
		} or nil
	end

	local node = node_id and api.uci_get_c(node_id) or nil
	local balancers = {}
	local rules = {}

	if local_socks_port then
		local inbound = {
			tag = "socks-in",
			listen = local_socks_address,
			port = tonumber(local_socks_port),
			protocol = "socks",
			settings = {auth = "noauth", udp = true},
			sniffing = {
				enabled = xray_settings.sniffing_override_dest == "1" or node.protocol == "_shunt"
			}
		}
		if inbound.sniffing.enabled == true then
			inbound.sniffing.destOverride = {"http", "tls", "quic"}
			inbound.sniffing.routeOnly = xray_settings.sniffing_override_dest ~= "1" or nil
			inbound.sniffing.domainsExcluded = xray_settings.sniffing_override_dest == "1" and get_domain_excluded() or nil
		end
		if local_socks_username and local_socks_password and local_socks_username ~= "" and local_socks_password ~= "" then
			inbound.settings.auth = "password"
			inbound.settings.users = {
				{
					user = local_socks_username,
					pass = local_socks_password
				}
			}
		end
		table.insert(inbounds, inbound)
	end

	if local_http_port then
		local inbound = {
			listen = local_http_address,
			port = tonumber(local_http_port),
			protocol = "http",
			settings = {allowTransparent = false}
		}
		if local_http_username and local_http_password and local_http_username ~= "" and local_http_password ~= "" then
			inbound.settings.users = {
				{
					user = local_http_username,
					pass = local_http_password
				}
			}
		end
		table.insert(inbounds, inbound)
	end

	function get_node_by_id(node_id)
		local section
		if type(node_id) == "table" then
			section = node_id
		elseif type(node_id) == "string" then
			if node_id == "" or node_id == "nil" then return nil end
			section = api.uci_get_c(node_id) or {}
		else
			return nil
		end
		if section[".type"] == "socks" then
			return {
				[".name"] = section[".name"],
				remarks = "socks[%s]" % section.port,
				type = "Xray",
				protocol = "socks",
				address = "127.0.0.1",
				port = section.port,
				transport = "raw",
				stream_security = "none"
			}
		end
		if section[".type"] == "nodes" then
			return section
		end
		return nil
	end

	function set_outbound_detour(node, outbound, outbounds_table)
		if not node or not outbound or not outbounds_table then return nil end
		local default_outTag = outbound.tag
		local last_insert_outbound

		if node.chain_proxy == "1" and node.preproxy_node then
			if outbound["_flag_proxy_tag"] then
				--Ignore
			else
				local preproxy_node = get_node_by_id(node.preproxy_node)
				if preproxy_node then
					local preproxy_outbound, exist
					if preproxy_node.protocol == "_balancing" then
						-- Xray's own "_balancing"/observatory AUTO mechanism was
						-- removed in Easy VLESS; skip gracefully instead of
						-- calling into the now-deleted gen_balancer().
						preproxy_outbound = nil
					else
						preproxy_outbound = gen_outbound(node[".name"], preproxy_node)
					end
					if preproxy_outbound then
						outbound.tag = preproxy_outbound.tag .. " -> " .. outbound.tag
						outbound.streamSettings = outbound.streamSettings or {}
						outbound.streamSettings.sockopt = outbound.streamSettings.sockopt or {}
						outbound.streamSettings.sockopt.dialerProxy = preproxy_outbound.tag
						if not exist then
							last_insert_outbound = preproxy_outbound
						end
						default_outTag = outbound.tag
					end
				end
			end
		end
		if node.chain_proxy == "2" and node.to_node then
			local to_node = get_node_by_id(node.to_node)
			if to_node then
				-- Landing Node not support use special node.
				if to_node.protocol and to_node.protocol:find("^_") then
					to_node = nil
				end
			end
			if to_node then
				local to_outbound
				if to_node.type ~= "Xray" then
					local in_tag = "inbound_" .. to_node[".name"] .. "_" .. tostring(outbound.tag)
					local new_port = api.get_new_port()
					table.insert(inbounds, {
						tag = in_tag,
						listen = "127.0.0.1",
						port = new_port,
						protocol = "tunnel",
						settings = {allowedNetwork = "tcp,udp", rewriteAddress = to_node.address, rewritePort = tonumber(to_node.port)}
					})
					if to_node.tls_serverName == nil then
						to_node.tls_serverName = to_node.address
					end
					to_node.address = "127.0.0.1"
					to_node.port = new_port
					table.insert(rules, 1, {
						inboundTag = {in_tag},
						outboundTag = outbound.tag
					})
					to_outbound = gen_outbound(node[".name"], to_node, to_node[".name"], {
						tag = to_node[".name"],
					})
				else
					to_outbound = gen_outbound(node[".name"], to_node)
				end
				if to_outbound then
					to_outbound.tag = outbound.tag .. " -> " .. to_outbound.tag
					if to_node.type == "Xray" then
						to_outbound.streamSettings = to_outbound.streamSettings or {}
						to_outbound.streamSettings.sockopt = to_outbound.streamSettings.sockopt or {}
						to_outbound.streamSettings.sockopt.dialerProxy = outbound.tag
					end
					table.insert(outbounds_table, to_outbound)
					default_outTag = to_outbound.tag
				end
			end
		end
		if node.chain_proxy == "3" and node.outbound_iface then
			if outbound.streamSettings and outbound.streamSettings.sockopt then
				outbound.streamSettings.sockopt.interface = node.outbound_iface
			end
		end
		return default_outTag, last_insert_outbound
	end

	function gen_outbound_get_tag(flag, node_id, tag, proxy_table)
		if not node_id or node_id == "" or node_id == "nil" then return nil end
		local node = get_node_by_id(node_id)
		if not tag then tag = node[".name"] end
		if node then
			if proxy_table.chain_proxy == "1" or proxy_table.chain_proxy == "2" then
				node.chain_proxy = proxy_table.chain_proxy
				node.preproxy_node = proxy_table.chain_proxy == "1" and proxy_table.preproxy_node
				node.to_node = proxy_table.chain_proxy == "2" and proxy_table.to_node
				proxy_table.chain_proxy = nil
				proxy_table.preproxy_node = nil
				proxy_table.to_node = nil
			end
			if tag == "default" then
				if default_node_address and default_node_port then
					node.address = default_node_address
					node.port = default_node_port
				end
			end
			local outbound, has_add_outbound
			for _, _outbound in ipairs(outbounds) do
				-- Avoid generating duplicate nested processes
				if _outbound["_flag_proxy_tag"] and _outbound["_flag_proxy_tag"]:find("socks <- " .. node[".name"], 1, true) then
					outbound = api.clone(_outbound)
					outbound.tag = tag
					break
				end
			end
			if node.protocol == "_balancing" then
				-- Xray's own "_balancing"/observatory AUTO mechanism was
				-- removed in Easy VLESS (this file's own gen_balancer() no
				-- longer exists); this resolver is also used by Shunt Rules,
				-- so a stray "_balancing" reference must not fall through
				-- into gen_outbound() below. Return nil / no tag gracefully.
				return nil
			elseif node.protocol == "_iface" then
				if node.iface then
					outbound = {
						tag = tag,
						protocol = "freedom",
						streamSettings = {
							sockopt = {
								mark = 255,
								interface = node.iface
							}
						},
						settings = {
							finalRules = {{ action = "allow" }}
						}
					}
					sys.call(string.format("mkdir -p %s && touch %s/%s", api.TMP_IFACE_PATH, api.TMP_IFACE_PATH, node.iface))
				end
			end
			if not outbound then
				outbound = gen_outbound(flag, node, tag, proxy_table)
			end
			if outbound then
				local default_outbound_tag, last_insert_outbound = set_outbound_detour(node, outbound, outbounds)
				if not has_add_outbound then
					local insert_index = #outbounds + 1
					if tag == "default" then
						insert_index = 1
					end
					table.insert(outbounds, insert_index, outbound)
				end
				if last_insert_outbound then
					table.insert(outbounds, last_insert_outbound)
				end
				return default_outbound_tag
			end
		end
	end

	if node then
		if node.protocol ~= "_shunt" then
			-- create shunt logic
			local tmp_node = {
				remarks = node.remarks,
				type = "Xray",
				protocol = "_shunt",
				default_node = node[".name"],
			}
			tmp_node.fakedns = remote_dns_fake
			tmp_node.default_fakedns = remote_dns_fake
			node = tmp_node
		end

		if server_host and server_port then
			default_node_address = server_host
			default_node_port = server_port
		end

		if node.protocol == "_shunt" then
			inner_fakedns = node.fakedns or "0"

			local function gen_shunt_node(rule_name, _node_id)
				if not rule_name then return nil end
				if not _node_id then _node_id = node[rule_name] end
				if _node_id == "_direct" then
					return "direct"
				elseif _node_id == "_blackhole" then
					return "blackhole"
				elseif _node_id == "_default" and rule_name ~= "default" then
					return "default"
				elseif _node_id then
					local proxy_table = {
						fragment = xray_settings.fragment == "1",
						noise = xray_settings.noise == "1",
					}
					local preproxy_node_id = node[rule_name .. "_proxy_tag"]
					if preproxy_node_id == _node_id then preproxy_node_id = nil end
					if preproxy_node_id then
						proxy_table.chain_proxy = "2"
						proxy_table.to_node = _node_id
						return gen_outbound_get_tag(flag, preproxy_node_id, rule_name, proxy_table)
					else
						return gen_outbound_get_tag(flag, _node_id, rule_name, proxy_table)
					end
				end
				return nil
			end

			--default_node
			local default_node_id = node.default_node or "_direct"
			local default_outboundTag = gen_shunt_node("default", default_node_id)
			COMMON.default_outbound_tag = default_outboundTag

			if inner_fakedns == "1" and node["default_fakedns"] == "1" then
				remote_dns_fake = true
			end

			--shunt rule
			api.uci_foreach_c("shunt_rules", function(e)
				-- Easy VLESS 0.5.0: merge prepared domain resources
				-- (shunt_rules.domain_resource) into the rule's domain list.
				e.domain_list = api.rule_domain_list(e)
				if node["shunt_group"] ~= e.group then
					return
				end
				local outboundTag = gen_shunt_node(e[".name"])
				if outboundTag and e.remarks then
					if outboundTag == "default" then
						outboundTag = default_outboundTag
					end
					local protocols = nil
					if e["protocol"] and e["protocol"] ~= "" then
						protocols = {}
						string.gsub(e["protocol"], '[^' .. " " .. ']+', function(w)
							table.insert(protocols, w)
						end)
					end
					local inboundTag = nil
					if e["inbound"] and e["inbound"] ~= "" then
						inboundTag = {}
						if e["inbound"]:find("tproxy") then
							if redir_port then
								table.insert(inboundTag, "tcp_redir")
								table.insert(inboundTag, "udp_redir")
							end
						end
						if e["inbound"]:find("socks") then
							if local_socks_port then
								table.insert(inboundTag, "socks-in")
							end
						end
					end
					local domains = nil
					if e.domain_list then
						local domain_table = {
							shunt_rule_name = e[".name"],
							outboundTag = outboundTag,
							domain = {},
							fakedns = nil,
						}
						domains = {}
						string.gsub(e.domain_list, '[^' .. "\r\n" .. ']+', function(w)
							if w:find("#") == 1 then return end
							if w:find("rule-set:", 1, true) == 1 or w:find("rs:") == 1 then return end
							if w:find("ext:", 1, true) == 1 then return end  -- Rule currently not support ext:
							table.insert(domains, w)
							table.insert(domain_table.domain, w)
						end)
						if inner_fakedns == "1" and node[e[".name"] .. "_fakedns"] == "1" and #domains > 0 then
							domain_table.fakedns = true
						end
						local b_add = true
						if #domains == 0 then
							-- No domain
							b_add = nil
							domains = nil
						end
						if outboundTag and b_add then
							table.insert(dns_domain_rules, api.clone(domain_table))
						end
					end
					local ip = nil
					if e.ip_list then
						ip = {}
						string.gsub(e.ip_list, '[^' .. "\r\n" .. ']+', function(w)
							if w:find("#") == 1 then return end
							if w:find("rule-set:", 1, true) == 1 or w:find("rs:") == 1 then return end
							if w:find("ext:", 1, true) == 1 then return end  -- Rule currently not support ext:
							table.insert(ip, w)
						end)
						if #ip == 0 then ip = nil end
					end
					local source = nil
					if e.source then
						source = {}
						string.gsub(e.source, '[^' .. " " .. ']+', function(w)
							table.insert(source, w)
						end)
					end
					local rule = {
						ruleTag = e.remarks,
						inboundTag = inboundTag,
						outboundTag = outboundTag,
						network = e["network"] or "tcp,udp",
						source = source,
						--sourcePort = e["sourcePort"] ~= "" and e["sourcePort"] or nil,
						port = e["port"] ~= "" and e["port"] or nil,
						protocol = protocols
					}
					if domains then
						local _rule = api.clone(rule)
						_rule.ruleTag = _rule.ruleTag .. " Domains"
						_rule.domains = domains
						table.insert(rules, _rule)
					end
					if ip then
						local _rule = api.clone(rule)
						_rule.ruleTag = _rule.ruleTag .. " IP"
						_rule.ip = ip
						table.insert(rules, _rule)
					end
					if not domains and not ip then
						table.insert(rules, rule)
					end
				end
			end)

			if default_outboundTag then
				local rule = {
					ruleTag = "default",
					outboundTag = default_outboundTag,
				}
				if node.domainStrategy == "IPIfNonMatch" then
					rule.port = "1-65535"
				else
					rule.network = "tcp,udp"
				end
				table.insert(rules, rule)
			end

			routing = {
				domainStrategy = node.domainStrategy or "AsIs",
				domainMatcher = node.domainMatcher or "hybrid",
				balancers = #balancers > 0 and balancers or nil,
				rules = rules
			}
		end
	end

	local dns_servers = {}
	local direct_dns_tag = "dns-in-direct"
	local remote_dns_tag = "dns-in-remote"
	local remote_fakedns_tag = "dns-in-remote-fakedns"
	local default_dns_tag = "dns-in-default"

	dns = {
		tag = "dns-global",
		hosts = {},
		disableCache = (dns_cache and dns_cache == "0") and true or false,
		disableFallback = true,
		disableFallbackIfMatch = true,
		servers = {},
		queryStrategy = "UseIP"
	}

	for i, v in pairs(GLOBAL.DNS_SERVER) do
		table.insert(dns_servers, {
			server = v,
			outboundTag = "direct"
		})
	end

	local _direct_dns = nil
	if direct_dns_udp_server then
		_direct_dns = {
			tag = direct_dns_tag,
			address = direct_dns_udp_server,
			port = tonumber(direct_dns_udp_port) or 53,
			queryStrategy = (direct_dns_query_strategy and direct_dns_query_strategy ~= "") and direct_dns_query_strategy or "UseIP"
		}
		table.insert(dns_servers, {
			outboundTag = "direct",
			server = _direct_dns
		})
	elseif direct_dns_tcp_server then
		if api.is_ipv6(direct_dns_tcp_server) then
			direct_dns_tcp_server = api.get_ipv6_full(direct_dns_tcp_server)
		end
		_direct_dns = {
			tag = direct_dns_tag,
			address = "tcp://" .. direct_dns_tcp_server .. ":" .. tonumber(direct_dns_tcp_port) or 53,
			port = tonumber(direct_dns_tcp_port) or 53,
			queryStrategy = (direct_dns_query_strategy and direct_dns_query_strategy ~= "") and direct_dns_query_strategy or "UseIP"
		}
		table.insert(dns_servers, {
			outboundTag = "direct",
			server = _direct_dns
		})
	end

	if next(GLOBAL.DNS_HOSTNAME) then
		local hostname = {}
		for line, _ in pairs(GLOBAL.DNS_HOSTNAME) do
			table.insert(hostname, line)
		end
		local new_dns_server
		if _direct_dns then
			new_dns_server = api.clone(_direct_dns)
		else
			new_dns_server = {
				address = "localhost"
			}
		end
		new_dns_server.tag = "dns-in-bootstrap"
		new_dns_server.domains = hostname
		table.insert(dns_servers, #dns_servers - 1, {
			outboundTag = "direct",
			server = new_dns_server
		})
	end

	if dns_listen_port then
		local _remote_dns_proto = "tcp"

		if not routing then
			routing = {
				domainStrategy = "IPOnDemand",
				rules = {}
			}
		end
	
		local dns_host = ""
		if flag == "global" then
			dns_host = api.uci_get_c("@global[0]", "dns_hosts") or ""
		else
			flag = flag:gsub("acl_", "")
			local dns_hosts_mode = api.uci_get_c(flag, "dns_hosts_mode") or "default"
			if dns_hosts_mode == "default" then
				dns_host = api.uci_get_c("@global[0]", "dns_hosts") or ""
			elseif dns_hosts_mode == "disable" then
				dns_host = ""
			elseif dns_hosts_mode == "custom" then
				dns_host = api.uci_get_c(flag, "dns_hosts") or ""
			end
		end
		if #dns_host > 0 then
			string.gsub(dns_host, '[^' .. "\r\n" .. ']+', function(w)
				local host = sys.exec(string.format("echo -n $(echo %s | awk -F ' ' '{print $1}')", w))
				local key = sys.exec(string.format("echo -n $(echo %s | awk -F ' ' '{print $2}')", w))
				if host ~= "" and key ~= "" then
					dns.hosts[host] = key
				end
			end)
		end
	
		local _remote_dns = {
			tag = remote_dns_tag,
			queryStrategy = (remote_dns_query_strategy and remote_dns_query_strategy ~= "") and remote_dns_query_strategy or "UseIPv4"
		}

		if remote_dns_udp_server then
			_remote_dns.address = remote_dns_udp_server
			_remote_dns.port = tonumber(remote_dns_udp_port) or 53
			_remote_dns_proto = "udp"
		end

		if remote_dns_tcp_server then
			if api.is_ipv6(remote_dns_tcp_server) then
				remote_dns_tcp_server = api.get_ipv6_full(remote_dns_tcp_server)
			end
			_remote_dns.address = "tcp://" .. remote_dns_tcp_server .. ":" .. tonumber(remote_dns_tcp_port) or 53
			_remote_dns.port = tonumber(remote_dns_tcp_port) or 53
			_remote_dns_proto = "tcp"
		end

		if remote_dns_doh_url and remote_dns_doh_host then
			if remote_dns_doh_ip and remote_dns_doh_host ~= remote_dns_doh_ip and not api.is_ip(remote_dns_doh_host) then
				dns.hosts[remote_dns_doh_host] = remote_dns_doh_ip
			end
			_remote_dns.address = remote_dns_doh_url
			_remote_dns.port = tonumber(remote_dns_doh_port) or 443
		end

		if _remote_dns.address then
			table.insert(dns_servers, {
				outboundTag = remote_dns_detour == "direct" and "direct" or nil,
				server = _remote_dns
			})
		end

		local _remote_fakedns = nil
		if remote_dns_fake or inner_fakedns == "1" then
			fakedns = {}
			local fakedns4 = {
				ipPool = "198.18.0.0/16",
				poolSize = 65535
			}
			local fakedns6 = {
				ipPool = "fc00::/18",
				poolSize = 65535
			}
			if remote_dns_query_strategy == "UseIP" then
				table.insert(fakedns, fakedns4)
				table.insert(fakedns, fakedns6)
			elseif remote_dns_query_strategy == "UseIPv4" then
				table.insert(fakedns, fakedns4)
			elseif remote_dns_query_strategy == "UseIPv6" then
				table.insert(fakedns, fakedns6)
			end
			_remote_fakedns = {
				tag = remote_fakedns_tag,
				address = "fakedns",
			}
			table.insert(dns_servers, {
				server = _remote_fakedns
			})
		end

		if direct_dns_udp_server or direct_dns_tcp_server then
			local domain = {}
			local nodes_domain_text = sys.exec('uci show easy_vless | grep ".address=" | cut -d "\'" -f 2 | grep "[a-zA-Z]$" | sort -u')
			string.gsub(nodes_domain_text, '[^' .. "\r\n" .. ']+', function(w)
				w = (w or ""):lower()
				table.insert(domain, "full:" .. w)
			end)
			if #domain > 0 then
				table.insert(dns.servers, 1, {
					tag = "dns-in-vpslist",
					address = "localhost",
					domains = domain,
					finalQuery = true,
					disableCache = false,
					serveStale = true,
				})
			end
		end

		local dns_outbound
		if dns_listen_port then
			table.insert(inbounds, {
				listen = "127.0.0.1",
				port = tonumber(dns_listen_port),
				protocol = "tunnel",
				tag = "dns-in",
				settings = {
					allowedNetwork = "tcp,udp"
				}
			})
			local direct_type_dns = {
				settings = {
					rewriteAddress = direct_dns_udp_server,
					rewritePort = tonumber(direct_dns_udp_port) or 53,
					rewriteNetwork = "udp",
					rules = {
						{
							qType = "1,28",
							action = "hijack"
						},
						{
							qType = 65,
							action = "return",
							rCode = 0
						},
						{
							action = "direct"
						}
					} or nil
				},
				streamSettings = {
					sockopt = { dialerProxy = "direct" }
				}
			}
			local remote_type_dns = {
				settings = {
					rewriteAddress = remote_dns_udp_server,
					rewritePort = tonumber(remote_dns_udp_port) or 53,
					rewriteNetwork = _remote_dns_proto or "tcp",
					rules = {
						{
							qType = "1,28",
							action = "hijack"
						},
						{
							action = "return",
							rCode = 0
						}
					} or nil
				}
			}
			local type_dns = direct_type_dns
			dns_outbound = {
				tag = "dns-out",
				protocol = "dns",
				streamSettings = type_dns.streamSettings,
				settings = type_dns.settings
			}
			table.insert(outbounds, dns_outbound)
			table.insert(routing.rules, 1, {
				inboundTag = {
					"dns-in"
				},
				outboundTag = "dns-out"
			})
		end
	
		local default_dns_tag_name = remote_dns_tag
		if not COMMON.default_outbound_tag or COMMON.default_outbound_tag == "direct" then
			default_dns_tag_name = direct_dns_tag
		end
	
		if dns_servers and #dns_servers > 0 then
			-- Default DNS logic
			local default_dns_server = nil
			for index, value in ipairs(dns_servers) do
				if not default_dns_server and value.server.tag == default_dns_tag_name then
					default_dns_server = api.clone(value)
					default_dns_server.server.tag = default_dns_tag
					if value.server.tag == remote_dns_tag then
						if remote_dns_fake then
							default_dns_server.server = api.clone(_remote_fakedns)
							default_dns_server.server.tag = default_dns_tag
						else
							default_dns_server.outboundTag = value.outboundTag or COMMON.default_outbound_tag
						end
					end
					table.insert(dns_servers, 1, default_dns_server)
					break
				end
			end

			-- Shunt rule DNS logic
			local dns_out_rules = {}
			if dns_domain_rules and #dns_domain_rules > 0 then
				for index, value in ipairs(dns_domain_rules) do
					if value.domain and value.outboundTag then
						local dns_server = nil
						local dns_outboundTag = value.outboundTag
						if value.dns_server then
							dns_server = api.clone(value.dns_server)
						elseif value.outboundTag == "direct" then
							dns_server = api.clone(_direct_dns)
						else
							if value.fakedns then
								dns_server = api.clone(_remote_fakedns)
							else
								dns_server = api.clone(_remote_dns)
								if remote_dns_detour == "direct" then
									dns_outboundTag = "direct"
								end
							end
						end
						if value.outboundTag == "blackhole" then
							table.insert(dns_out_rules, {
								action = "return",
								rCode = 0,
								domain = api.clone(value.domain)
							})
							dns_server = nil
						else
							table.insert(dns_out_rules, {
								action = "hijack",
								qType = "1,28",
								domain = api.clone(value.domain)
							})
						end
						if dns_server then
							dns_server.finalQuery = true
							dns_server.domains = value.domain
							if value.shunt_rule_name then
								dns_server.tag = "dns-in-" .. value.shunt_rule_name
							end
							table.insert(dns_servers, {
								outboundTag = dns_outboundTag,
								server = dns_server
							})
						end
					end
				end
				if dns_outbound and dns_outbound.settings.rules and #dns_out_rules > 0 then
					for i = #dns_out_rules, 1, -1 do
						table.insert(dns_outbound.settings.rules, 1, dns_out_rules[i])
					end
				end
			end
		end

		local default_rule_index = nil
		for index, value in ipairs(routing.rules) do
			if value.ruleTag == "default" then
				default_rule_index = index
				break
			end
		end
		if default_rule_index then
			local default_rule = api.clone(routing.rules[default_rule_index])
			table.remove(routing.rules, default_rule_index)
			table.insert(routing.rules, default_rule)
		end

		local content = flag .. node_id .. jsonc.stringify(routing.rules)
		if api.cacheFileCompareToLogic(CACHE_TEXT_FILE, content) == false then
			--clear ipset/nftset
			if direct_ipset then
				string.gsub(direct_ipset, '[^' .. "," .. ']+', function(w)
					sys.call("ipset -q -F " .. w)
				end)
				local ipset_prefix_name = "ev_" .. node_id .. "_"
				local ipset_list = sys.exec("ipset list | grep 'Name: ' | grep '" .. ipset_prefix_name .. "' | awk '{print $2}'")
				string.gsub(ipset_list, '[^' .. "\r\n" .. ']+', function(w)
					sys.call("ipset -q -F " .. w)
				end)
			end
			if direct_nftset then
				string.gsub(direct_nftset, '[^' .. "," .. ']+', function(w)
					local split = api.split(w, "#")
					if #split > 3 then
						local ip_type = split[1]
						local family = split[2]
						local table_name = split[3]
						local set_name = split[4]
						sys.call(string.format("nft flush set %s %s %s 2>/dev/null", family, table_name, set_name))
					end
				end)
				local family = "inet"
				local table_name = "easy_vless"
				local nftset_prefix_name = "ev_" .. node_id .. "_"
				local nftset_list = sys.exec("nft -a list sets | grep -E '" .. nftset_prefix_name .. "' | awk -F 'set ' '{print $2}' | awk '{print $1}'")
				string.gsub(nftset_list, '[^' .. "\r\n" .. ']+', function(w)
					sys.call(string.format("nft flush set %s %s %s 2>/dev/null", family, table_name, w))
				end)
			end
		end
	end

	if not next(dns.hosts) then
		dns.hosts = nil
	end

	for i = #dns_servers, 1, -1 do
		local value = dns_servers[i]
		if value.server.tag ~= direct_dns_tag and value.server.tag ~= remote_dns_tag then
			-- DNS rule must be at the front, prevents being matched by rules.
			if value.outboundTag and value.server.address ~= "fakedns" then
				table.insert(routing.rules, 1, {
					inboundTag = {
						value.server.tag
					},
					outboundTag = value.outboundTag,
				})
			end
			if (value.server.domains and #value.server.domains > 0) or value.server.tag == default_dns_tag then
				-- Only keep default DNS server or has domains DNS server.
				table.insert(dns.servers, 1, value.server)
			end
		end
	end

	local has_default_dns_server = "0"
	for index, value in ipairs(dns.servers) do
		if value.domains == nil then
			has_default_dns_server = "1"
			break
		end
	end

	if #dns.servers == 0 or not has_default_server == "0" then
		table.insert(dns.servers, 1, {
			tag = "local",
			address = "localhost"
		})
	end

	if redir_port then
		local inbound = {
			port = tonumber(redir_port),
			protocol = "tunnel",
			settings = {allowedNetwork = "tcp,udp", followRedirect = true},
			streamSettings = {sockopt = {tproxy = "tproxy"}},
			sniffing = {
				enabled = xray_settings.sniffing_override_dest == "1" or node.protocol == "_shunt"
			}
		}
		if inbound.sniffing.enabled == true then
			inbound.sniffing.destOverride = {"http", "tls", "quic"}
			inbound.sniffing.metadataOnly = false
			inbound.sniffing.routeOnly = xray_settings.sniffing_override_dest ~= "1" or nil
			inbound.sniffing.domainsExcluded = xray_settings.sniffing_override_dest == "1" and get_domain_excluded() or nil
		end
		if remote_dns_fake or inner_fakedns == "1" then
			inbound.sniffing.enabled = true
			if not inbound.sniffing.destOverride then
				inbound.sniffing.destOverride = {"fakedns"}
				inbound.sniffing.metadataOnly = true
			else
				table.insert(inbound.sniffing.destOverride, "fakedns")
				inbound.sniffing.metadataOnly = false
			end
		end

		local tcp_inbound = api.clone(inbound)
		tcp_inbound.tag = "tcp_redir"
		tcp_inbound.settings.allowedNetwork = "tcp"
		tcp_inbound.streamSettings.sockopt.tproxy = tcp_proxy_way
		table.insert(inbounds, tcp_inbound)

		local udp_inbound = api.clone(inbound)
		udp_inbound.tag = "udp_redir"
		udp_inbound.settings.allowedNetwork = "udp"
		table.insert(inbounds, udp_inbound)
	end
	
	if inbounds or outbounds then
		local config = {
			env = (function()
				local asset_location = api.uci_get_c("@global_rules[0]", "v2ray_location_asset") or "/usr/share/v2ray/"
				return { XRAY_LOCATION_ASSET = asset_location }
			end)(),
			log = {
				--access = string.format("%s/%s_access.log", TMP_PATH, "global"),
				--error = string.format("%s/%s_error.log", TMP_PATH, "global"),
				--dnsLog = true,
				loglevel = get_log_level(loglevel)
			},
			dns = dns,
			fakedns = fakedns,
			inbounds = inbounds,
			outbounds = outbounds,
			observatory = (not burstObservatory) and observatory or nil,
			burstObservatory = burstObservatory,
			routing = routing,
			policy = {
				levels = {
					[0] = {
						-- handshake = 4,
						-- connIdle = 300,
						-- uplinkOnly = 2,
						-- downlinkOnly = 5,
						bufferSize = xray_settings.buffer_size and tonumber(xray_settings.buffer_size) or nil,
						statsUserUplink = false,
						statsUserDownlink = false
					}
				},
				-- system = {
				--     statsInboundUplink = false,
				--     statsInboundDownlink = false
				-- }
			},
			version = {
				min = xray_min_version
			}
		}

		local direct_outbound = {
			protocol = "freedom",
			tag = "direct",
			settings = {
				finalRules = {{ action = "allow" }}
			} or nil,
			streamSettings = {
				sockopt = {
					mark = 255,
					domainStrategy = (direct_dns_query_strategy and direct_dns_query_strategy ~= "") and direct_dns_query_strategy or "UseIP"
				}
			}
		}
		if COMMON.default_outbound_tag == "direct" then
			table.insert(outbounds, 1, direct_outbound)
		else
			table.insert(outbounds, direct_outbound)
		end

		local blackhole_outbound = {
			protocol = "blackhole",
			tag = "blackhole"
		}
		if COMMON.default_outbound_tag == "blackhole" then
			table.insert(outbounds, 1, blackhole_outbound)
		else
			table.insert(outbounds, blackhole_outbound)
		end

		for index, value in ipairs(config.outbounds) do
			local s = value.settings
			if not value["_flag_proxy_tag"] and value["_id"] and s and not NO_RUN and
			((s.vnext and s.vnext[1] and s.vnext[1].address and s.vnext[1].port) or 
			(s.servers and s.servers[1] and s.servers[1].address and s.servers[1].port) or
			(s.peers and s.peers[1] and s.peers[1].endpoint) or
			(s.address and s.port)) then
				sys.call(string.format("echo '%s' >> %s", value["_id"], api.TMP_PATH .. "/direct_node_list"))
			end
			for k, v in pairs(config.outbounds[index]) do
				if k:find("_") == 1 then
					config.outbounds[index][k] = nil
				end
			end
		end
		return jsonc.stringify(config, 1)
	end
end

function gen_proto_config(var)
	local local_socks_address = var["local_socks_address"] or "0.0.0.0"
	local local_socks_port = var["local_socks_port"]
	local local_socks_username = var["local_socks_username"]
	local local_socks_password = var["local_socks_password"]
	local local_http_address = var["local_http_address"] or "0.0.0.0"
	local local_http_port = var["local_http_port"]
	local local_http_username = var["local_http_username"]
	local local_http_password = var["local_http_password"]
	local server_proto = var["server_proto"]
	local server_address = var["server_address"]
	local server_port = var["server_port"]
	local server_username = var["server_username"]
	local server_password = var["server_password"]
	
	local inbounds = {}
	local outbounds = {}
	local routing = nil

	if local_socks_address and local_socks_port then
		local inbound = {
			listen = local_socks_address,
			port = tonumber(local_socks_port),
			protocol = "socks",
			settings = {
				udp = true,
				auth = "noauth"
			}
		}
		if local_socks_username and local_socks_password and local_socks_username ~= "" and local_socks_password ~= "" then
			inbound.settings.auth = "password"
			inbound.settings.users = {
				{
					user = local_socks_username,
					pass = local_socks_password
				}
			}
		end
		table.insert(inbounds, inbound)
	end
	
	if local_http_address and local_http_port then
		local inbound = {
			listen = local_http_address,
			port = tonumber(local_http_port),
			protocol = "http",
			settings = {
				allowTransparent = false
			}
		}
		if local_http_username and local_http_password and local_http_username ~= "" and local_http_password ~= "" then
			inbound.settings.users = {
				{
					user = local_http_username,
					pass = local_http_password
				}
			}
		end
		table.insert(inbounds, inbound)
	end
	
	if server_proto ~= "nil" and server_address ~= "nil" and server_port ~= "nil" then
		local outbound = {
			protocol = server_proto,
			streamSettings = {
				method = "raw",
				security = "none"
			},
			settings = {
				servers = {
					{
						address = server_address,
						port = tonumber(server_port),
						users = (server_username and server_password) and {
							{
								user = server_username,
								pass = server_password
							}
						} or nil
					}
				}
			}
		}
		if outbound then table.insert(outbounds, outbound) end
	end

	table.insert(outbounds, {
		protocol = "freedom",
		tag = "direct",
		settings = {
			finalRules = {{ action = "allow" }}
		} or nil,
		streamSettings = {
			sockopt = {mark = 255}
		}
	})
	
	local config = {
		log = {
			loglevel = "warning"
		},
		inbounds = inbounds,
		outbounds = outbounds,
		routing = routing,
		version = {
			min = xray_min_version
		}
	}
	return jsonc.stringify(config, 1)
end

_G.gen_config = gen_config
_G.gen_proto_config = gen_proto_config

if arg[1] then
	local func =_G[arg[1]]
	if func then
		local var = nil
		if arg[2] then
			var = jsonc.parse(arg[2])
		end
		print(func(var))
	end
end
