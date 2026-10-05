-- Easy VLESS 1.1 - Trojan: regression test of the link / subscription
-- parsers (root/usr/share/easy_vless/subscribe.lua), of the sing-box outbound
-- (util_sing-box.lua gen_outbound) and of the node identity (nodes.lua) with
-- a stock Lua 5.1.
--
--   lua5.1 tests/trojan-test.lua      (static checks, CI "checks" job)
--
-- The real files are loaded; only what needs a router is replaced (UCI, the
-- file system, nixio, the log). Covered: trojan:// links (password, address,
-- port, TLS, SNI, insecure, transports), what a link must not do (a hostile
-- name, password or host stays data), Clash and sing-box JSON subscriptions,
-- mixed VLESS + Trojan lists, the generated outbound, and that VLESS is
-- parsed and generated exactly as before.

package.path = "root/usr/lib/lua/?.lua;" .. package.path

local pass, fail = 0, 0
local function check(msg, cond)
	if cond then pass = pass + 1 print("PASS: " .. msg)
	else fail = fail + 1 print("FAIL: " .. msg) end
end

-- ---------------------------------------------------------------- stand-ins
local LOG = {}
local function hostname(v)
	return type(v) == "string" and #v <= 253 and v:match("^[%w_][%w_%-%.]*$") ~= nil and not v:match("^[%d%.]+$")
end
local function ip4addr(v)
	local a, b, c, d = tostring(v):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return false end
	for _, x in ipairs({ a, b, c, d }) do if tonumber(x) > 255 then return false end end
	return true
end
local function ip6addr(v)
	return type(v) == "string" and v:find(":", 1, true) ~= nil and v:match("^[%x:%.]+$") ~= nil
end
local cursor = setmetatable({}, { __index = function() return function() return nil end end })
package.preload["nixio"] = function()
	return { getpid = function() return 1 end, nanosleep = function() end,
		bin = { b64decode = function() return nil end, b64encode = function(s) return s end } }
end
package.preload["nixio.fs"] = function()
	return { access = function() return false end, readfile = function() return nil end }
end
package.preload["luci.sys"] = function()
	return { call = function() return 1 end, exec = function() return "" end }
end
package.preload["luci.model.uci"] = function() return { cursor = function() return cursor end } end
package.preload["luci.util"] = function() return {} end
package.preload["luci.cbi.datatypes"] = function()
	return { hostname = hostname, ip4addr = ip4addr, ip6addr = ip6addr,
		ipaddr = function(v) return ip4addr(v) or ip6addr(v) end,
		port = function(v) v = tonumber(v) return v ~= nil and v >= 0 and v <= 65535 end }
end
package.preload["luci.jsonc"] = function()
	return { parse = function() error("no JSON parser in this test") end, stringify = function() return "{}" end }
end
package.preload["luci.i18n"] = function()
	return { default = "en", setlanguage = function() end,
		translate = function(s) return s end,
		translatef = function(s, ...) return string.format(s, ...) end }
end
package.preload["lyaml"] = function() return { load = function() return nil end } end

local api = require "luci.easy_vless.api"
api.log = function(level, ...) LOG[#LOG + 1] = table.concat({ ... }, " ") end
api.finded_com = function(name) return name == "sing-box" and "/usr/bin/sing-box" or nil end
api.is_finded = function() return false end
api.get_core = function(field, candidates)
	for _, c in ipairs(candidates) do if c[1] then return c[2] end end
end
api.get_app_version = function() return "1.12.0" end
api.uci_get_c = function() return nil end
api.uci_set_c = function() end
api.uci_del_c = function() end
api.uci_save_c = function() end
api.uci_foreach_c = function() end

-- subscribe.lua is a script: its parsers are local functions. Load its text
-- and hand them out; without arguments nothing else runs.
arg = {}
local f = assert(io.open("root/usr/share/easy_vless/subscribe.lua", "r"))
local src = f:read("*a"):gsub("^#![^\n]*", "")
f:close()
local chunk = assert(loadstring(src .. "\nreturn { processData = processData, processClashData = processClashData,"
	.. " processSingBoxData = processSingBoxData, parse_link = parse_link, nodeResult = nodeResult }", "subscribe.lua"))
local S = chunk()
local SB = require "luci.easy_vless.util_sing-box"
local N = require "luci.easy_vless.nodes"

local UUID = "00000000-0000-4000-8000-000000000001"
local PW = "secret" -- the test password of the fixtures below
local function link(l)
	local scheme, rest = l:match("^(%a+)://(.*)$")
	return S.processData(scheme, rest, "1", "")
end
local function logged(text)
	for _, l in ipairs(LOG) do if l:find(text, 1, true) then return true end end
	return false
end

-- ---------------------------------------------------------------- trojan://
local n = link("trojan://pass%40word@tr.example.com:443?sni=sni.example.com#My%20Trojan")
check("link: protocol trojan on sing-box", n and n.protocol == "trojan" and n.type == "sing-box")
check("link: password is URL-decoded", n.password == "pass@word")
check("link: address, port and name", n.address == "tr.example.com" and n.port == "443" and n.remarks == "My Trojan")
check("link: TLS is on without a security parameter, with the SNI of the link", n.tls == "1" and n.tls_serverName == "sni.example.com")
check("link: the certificate is verified unless the link says otherwise", n.tls_allowInsecure == "0")
check("link: plain TCP transport", n.transport == "tcp")
check("link: no VLESS options on a Trojan node", n.uuid == nil and n.flow == nil and n.encryption == nil)
check("link: nothing wrong with it", n.error_msg == nil)

n = link("trojan://secret@198.51.100.5:8443?type=ws&host=cdn.example.com&path=%2Ftr%3Fed%3D2048&security=tls&sni=cdn.example.com&allowInsecure=1&fp=firefox&alpn=h2%2Chttp%2F1.1#WS")
check("link ws: transport, host and path", n.transport == "ws" and n.ws_host == "cdn.example.com" and n.ws_path == "/tr")
check("link ws: early data taken from the path", n.ws_enableEarlyData == "1" and n.ws_maxEarlyData == 2048)
check("link ws: allowInsecure=1 is kept", n.tls_allowInsecure == "1")
check("link ws: uTLS fingerprint and ALPN", n.utls == "1" and n.fingerprint == "firefox" and n.alpn == "h2,http/1.1")
check("link ws: port of the link", n.port == "8443" and n.address == "198.51.100.5")

n = link("trojan://secret@tr.example.com:443?type=grpc&serviceName=svc&sni=tr.example.com#gRPC")
check("link grpc: service name", n.transport == "grpc" and n.grpc_serviceName == "svc" and n.grpc_mode == "gun")
n = link("trojan://secret@tr.example.com:443?type=httpupgrade&host=h.example.com&path=%2Fup#HU")
check("link httpupgrade: host and path", n.transport == "httpupgrade" and n.httpupgrade_host == "h.example.com" and n.httpupgrade_path == "/up")
n = link("trojan://secret@tr.example.com:80?security=none#Plain")
check("link: security=none turns TLS off", n.tls == "0" and n.tls_serverName == nil)
n = link("trojan://secret@198.51.100.6:443?peer=peer.example.com#Peer")
check("link: peer= is the SNI when sni= is missing", n.tls == "1" and n.tls_serverName == "peer.example.com")
n = link("trojan://secret@tr.example.com:443?security=reality&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=01&sni=www.example.com&fp=chrome#Reality")
check("link: Reality parameters", n.reality == "1" and n.reality_publicKey == ("A"):rep(43) and n.reality_shortId == "01" and n.tls == "1")
n = link("trojan://p@ss@tr.example.com:443#At")
check("link: a raw @ in the password does not move the address", n.password == "p@ss" and n.address == "tr.example.com" and n.port == "443")
n = link("trojan://secret@tr.example.com:443?path=/a@b&type=ws#AtInPath")
check("link: an @ in a parameter is not taken for the end of the password", n.password == "secret" and n.address == "tr.example.com" and n.ws_path == "/a@b")
n = link("trojan://secret@[2001:db8::1]:8443?sni=v6.example.com#V6")
check("link: IPv6 address in brackets", n.address == "2001:db8::1" and n.port == "8443")
n = link("trojan://secret@tr.example.com:443?flow=xtls-rprx-vision&encryption=none#Flow")
check("link: flow / encryption of a VLESS link are not taken over", n.flow == nil and n.encryption == nil and n.protocol == "trojan")

-- ---------------------------------------------------------------- validation
n = link("trojan://@tr.example.com:443#NoPassword")
check("validation: an empty password is refused with a reason", n ~= nil and n.error_msg == "password missing")
n = link("trojan://tr.example.com:443#NoUserinfo")
check("validation: a link without password@ has no usable address", n ~= nil and (n.address == nil or n.error_msg ~= nil))
LOG = {}
n = link("trojan://secret@tr.example.com:443?type=xhttp&path=%2Fx#XHTTP")
check("validation: a transport sing-box does not have is skipped, not handed to Xray", n == nil and logged("Sing-Box does not support"))
n = link("trojan://secret@tr.example.com:443?type=kcp#KCP")
check("validation: mKCP is skipped", n == nil)

-- hostile values: what a link carries is data
local EVIL_PW = "$(touch /tmp/evtest-pwned)`id`';\"|&"
n = link("trojan://" .. api.UrlEncode(EVIL_PW) .. "@tr.example.com:443#Evil")
check("hostile password: kept verbatim as a value", n.password == EVIL_PW and n.address == "tr.example.com")

-- the whole path of "Import URL": lines -> parser -> filter (parse_link)
local function import(text)
	for i = #S.nodeResult, 1, -1 do S.nodeResult[i] = nil end
	LOG = {}
	local count = S.parse_link(text, "1", "")
	return S.nodeResult[1] and S.nodeResult[1].list or {}, count
end
local function by(list, name)
	for _, x in ipairs(list) do if x.remarks == name then return x end end
end
local list, count = import(table.concat({
	"vless://" .. UUID .. "@198.51.100.61:443?encryption=none&type=tcp&security=none#Mixed%20VLESS",
	"trojan://secret@198.51.100.62:443?sni=a.example.com#Mixed%20Trojan",
	"trojan://secret@198.51.100.63:44x3#Bad%20port",
	"trojan://secret@198.51.100.64:99999#Port%20range",
	"trojan://@198.51.100.65:443#No%20password",
	"trojan://secret@198.51.100.66:443#Line%0Abreak%20%3Cscript%3Ealert(1)%3C%2Fscript%3E",
	"trojan://pw%0Aline@198.51.100.67:443#Control",
	"trojan://secret@bad%20host%3Breboot:443#Bad%20host",
	"trojan://secret@127.0.0.1:443#Loopback",
	"ss://YWVzLTI1Ni1nY206cGFzcw@192.0.2.1:8388#only-ss",
}, "\n"))
check("mixed list: 4 of 10 lines are servers (" .. count .. ")", count == 4 and #list == 4)
check("mixed list: the VLESS server", by(list, "Mixed VLESS") ~= nil and by(list, "Mixed VLESS").protocol == "vless" and by(list, "Mixed VLESS").uuid == UUID)
check("mixed list: the Trojan server", by(list, "Mixed Trojan") ~= nil and by(list, "Mixed Trojan").protocol == "trojan" and by(list, "Mixed Trojan").password == "secret")
check("mixed list: a port that is not a port is refused", by(list, "Bad port") == nil and by(list, "Port range") == nil and logged("invalid port"))
check("mixed list: a Trojan link without password is refused", by(list, "No password") == nil and logged("password missing"))
local hostile = by(list, "Linebreak scriptalert(1)/script")
check("hostile name: no line break and no tags reach the node list", hostile ~= nil and hostile.address == "198.51.100.66")
check("hostile password: control characters are removed", by(list, "Control") ~= nil and by(list, "Control").password == "pwline")
check("hostile host: not a host name, refused", by(list, "Bad host") == nil and by(list, "Loopback") == nil)
check("mixed list: another protocol is skipped with a reason", logged("ss type node subscriptions are not currently supported"))
for _, x in ipairs(list) do
	for k, v in pairs(x) do
		if type(v) == "string" and v:find("%c") then check("no control character in " .. k, false) end
	end
end

-- ---------------------------------------------------------------- Clash
local clash = S.processClashData({ proxies = {
	{ name = "C VLESS", type = "vless", server = "198.51.100.70", port = 443, uuid = UUID, tls = true, servername = "v.example.com" },
	{ name = "C Trojan", type = "trojan", server = "tr.example.com", port = 443, password = PW, sni = "sni.example.com",
		["skip-cert-verify"] = true, alpn = { "h2", "http/1.1" }, ["client-fingerprint"] = "chrome" },
	{ name = "C Trojan WS", type = "trojan", server = "198.51.100.71", port = 8443, password = 12345, network = "ws",
		["ws-opts"] = { path = "/tr", headers = { Host = "cdn.example.com" } } },
	{ name = "C Trojan gRPC", type = "trojan", server = "198.51.100.72", port = 443, password = PW, network = "grpc",
		["grpc-opts"] = { ["grpc-service-name"] = "svc" } },
	{ name = "C Trojan no password", type = "trojan", server = "198.51.100.73", port = 443 },
	{ name = "C SS", type = "ss", server = "198.51.100.74", port = 8388, cipher = "aes-128-gcm", password = "x" },
} }, "2", "Provider")
local c = by(clash, "C Trojan")
check("clash: Trojan proxy (always TLS, SNI, skip-cert-verify)", c ~= nil and c.protocol == "trojan" and c.type == "sing-box" and c.password == "secret"
	and c.tls == "1" and c.tls_serverName == "sni.example.com" and c.tls_allowInsecure == "1" and c.transport == "tcp")
check("clash: ALPN list and fingerprint", c.alpn == "h2,http/1.1" and c.utls == "1" and c.fingerprint == "chrome")
c = by(clash, "C Trojan WS")
check("clash: WebSocket options, a numeric password is text", c ~= nil and c.transport == "ws" and c.ws_path == "/tr" and c.ws_host == "cdn.example.com"
	and c.password == "12345" and c.tls_allowInsecure == "0")
c = by(clash, "C Trojan gRPC")
check("clash: gRPC service name", c ~= nil and c.transport == "grpc" and c.grpc_serviceName == "svc")
check("clash: a Trojan proxy without password is marked invalid", by(clash, "C Trojan no password").error_msg == "password missing")
c = by(clash, "C VLESS")
check("clash: the VLESS proxy next to them is unchanged", c ~= nil and c.protocol == "vless" and c.uuid == UUID and c.tls == "1" and c.tls_serverName == "v.example.com" and c.password == nil)
check("clash: another type gets no core (it is discarded by the filter)", by(clash, "C SS") ~= nil and by(clash, "C SS").type == nil)

-- ---------------------------------------------------------------- sing-box JSON
local sb, report = S.processSingBoxData({ outbounds = {
	{ type = "vless", tag = "SB VLESS", server = "198.51.100.80", server_port = 443, uuid = UUID, flow = "xtls-rprx-vision",
		tls = { enabled = true, server_name = "www.example.com", utls = { enabled = true, fingerprint = "chrome" },
			reality = { enabled = true, public_key = ("A"):rep(43), short_id = "01" } } },
	{ type = "trojan", tag = "SB Trojan", server = "tr.example.com", server_port = 443, password = PW,
		tls = { enabled = true, server_name = "sni.example.com", insecure = true, alpn = { "h2" } } },
	{ type = "trojan", server = "198.51.100.81", server_port = 8443, password = PW,
		tls = { enabled = true }, transport = { type = "ws", path = "/tr", headers = { Host = "cdn.example.com" }, max_early_data = 2048 } },
	{ type = "trojan", tag = "SB Trojan broken", server = "198.51.100.82", server_port = 443 },
	{ type = "trojan", tag = "SB Trojan quic", server = "198.51.100.83", server_port = 443, password = "x", transport = { type = "splithttp" } },
	{ type = "shadowsocks", tag = "ss", server = "198.51.100.84", server_port = 8388, method = "aes-128-gcm", password = "x" },
	{ type = "direct", tag = "direct" },
	{ type = "selector", tag = "select", outbounds = { "SB VLESS", "SB Trojan" } },
} }, "2", "Provider")
c = by(sb, "SB Trojan")
check("sing-box JSON: Trojan outbound", c ~= nil and c.protocol == "trojan" and c.type == "sing-box" and c.password == "secret" and c.address == "tr.example.com" and c.port == "443")
check("sing-box JSON: TLS, SNI, insecure, ALPN", c.tls == "1" and c.tls_serverName == "sni.example.com" and c.tls_allowInsecure == "1" and c.alpn == "h2")
check("sing-box JSON: no VLESS options on the Trojan node", c.uuid == nil and c.flow == nil and c.encryption == nil)
c = by(sb, "Trojan 2")
check("sing-box JSON: a Trojan outbound without tag is named, WebSocket transport", c ~= nil and c.transport == "ws" and c.ws_path == "/tr" and c.ws_host == "cdn.example.com"
	and c.ws_maxEarlyData == 2048 and c.tls_allowInsecure == "0")
check("sing-box JSON: a Trojan outbound without password is marked invalid", by(sb, "SB Trojan broken").error_msg == "server / server_port / password missing")
c = by(sb, "SB VLESS")
check("sing-box JSON: the VLESS outbound next to them is unchanged", c ~= nil and c.protocol == "vless" and c.uuid == UUID and c.flow == "xtls-rprx-vision"
	and c.reality == "1" and c.encryption == "none" and c.password == nil)
check("sing-box JSON: 5 server outbounds found, 2 skipped (unknown transport, shadowsocks), 2 ignored",
	report.found == 5 and report.skipped == 2 and report.ignored == 2 and report.skipped_types["trojan (invalid)"] == 1 and report.skipped_types["shadowsocks"] == 1)

-- ---------------------------------------------------------------- outbound
local function outbound(node)
	node[".name"] = node[".name"] or "srv"
	node[".type"] = "nodes"
	return SB.gen_outbound("test", node, "tag")
end
local o = outbound({ type = "sing-box", protocol = "trojan", remarks = "T", address = "TR.example.com", port = "443", password = EVIL_PW,
	transport = "tcp", tls = "1", tls_serverName = "sni.example.com", tls_allowInsecure = "0" })
check("outbound: type trojan with server and port", o ~= nil and o.type == "trojan" and o.server == "tr.example.com" and o.server_port == 443)
check("outbound: the password is passed as it is", o.password == EVIL_PW)
check("outbound: TLS with the SNI, the certificate is verified", type(o.tls) == "table" and o.tls.enabled == true and o.tls.server_name == "sni.example.com" and not o.tls.insecure)
check("outbound: no VLESS fields (uuid, flow, packet_encoding)", o.uuid == nil and o.flow == nil and o.packet_encoding == nil)
check("outbound: plain TCP has no transport block", o.transport == nil and o.multiplex == nil)
o = outbound({ type = "sing-box", protocol = "trojan", address = "198.51.100.5", port = "8443", password = PW, transport = "ws",
	ws_host = "cdn.example.com", ws_path = "/tr", ws_maxEarlyData = "2048", ws_earlyDataHeaderName = "Sec-WebSocket-Protocol",
	tls = "1", tls_allowInsecure = "1", alpn = "h2,http/1.1", utls = "1", fingerprint = "firefox" })
check("outbound ws: transport block", type(o.transport) == "table" and o.transport.type == "ws" and o.transport.path == "/tr"
	and o.transport.headers.Host == "cdn.example.com" and o.transport.max_early_data == 2048)
check("outbound ws: insecure, ALPN and uTLS", o.tls.insecure == true and o.tls.alpn[1] == "h2" and o.tls.alpn[2] == "http/1.1" and o.tls.utls.fingerprint == "firefox")
o = outbound({ type = "sing-box", protocol = "trojan", address = "tr.example.com", port = "443", password = PW, transport = "grpc",
	grpc_serviceName = "svc", tls = "1", reality = "1", reality_publicKey = ("A"):rep(43), reality_shortId = "01" })
check("outbound grpc + Reality", o.transport.type == "grpc" and o.transport.service_name == "svc" and o.tls.reality.enabled == true
	and o.tls.reality.public_key == ("A"):rep(43) and o.tls.utls.enabled == true)
o = outbound({ type = "sing-box", protocol = "trojan", address = "tr.example.com", port = "80", password = PW, transport = "tcp", tls = "0" })
check("outbound: without TLS there is no tls block", o.type == "trojan" and o.tls == nil)
o = outbound({ type = "sing-box", protocol = "vless", address = "v.example.com", port = "443", uuid = UUID, flow = "xtls-rprx-vision",
	transport = "tcp", tls = "1", tls_serverName = "v.example.com" })
check("outbound: VLESS is generated as before", o.type == "vless" and o.uuid == UUID and o.flow == "xtls-rprx-vision" and o.packet_encoding == "xudp"
	and o.password == nil and o.tls.enabled == true)

-- ---------------------------------------------------------------- identity
local vless = { protocol = "vless", address = "s.example.com", port = "443", uuid = UUID, transport = "tcp", tls_serverName = "s.example.com" }
local t1 = { protocol = "trojan", address = "s.example.com", port = "443", password = PW, transport = "tcp", tls_serverName = "s.example.com" }
local t2 = { protocol = "trojan", address = "s.example.com", port = "443", password = "other", transport = "tcp", tls_serverName = "s.example.com" }
local t3 = { protocol = "trojan", address = "S.example.com", port = "443", password = PW, transport = "tcp", tls_serverName = "s.example.com", remarks = "renamed", alpn = "h2" }
-- the key of 1.0 for this VLESS node: "deleted nodes" lists written by 1.0 keep working
check("identity: the key of a VLESS node is the one 1.0 computed (" .. N.key(vless) .. ")", N.key(vless) == "1ce18c35ca849d23")
check("identity: a Trojan node on the same address is another server", N.key(t1) ~= N.key(vless))
check("identity: another password is another server", N.key(t1) ~= N.key(t2))
check("identity: name and tuning options do not change the key", N.key(t1) == N.key(t3))
check("identity: Trojan is a server", N.is_server({ [".type"] = "nodes", protocol = "trojan" }) and not N.is_server({ [".type"] = "nodes", protocol = "_urltest" }))
local keep, stats = N.merge({ { [".name"] = "old1", protocol = "trojan", address = "s.example.com", port = "443", password = PW, transport = "tcp", tls_serverName = "s.example.com", remarks = "old name" } },
	{ t3, vless })
check("merge: a Trojan node of a subscription keeps its section id on update", keep[1] == "old1" and keep[2] == nil and stats.new == 1)

print(string.format("\n===== Trojan: %d passed, %d failed =====", pass, fail))
os.exit(fail == 0 and 0 or 1)
