-- Easy VLESS - Route Explain (0.9.0): unit / regression test of
-- root/usr/lib/lua/luci/easy_vless/explain.lua with a stock Lua 5.1.
--
--   lua5.1 tests/explain-test.lua      (static checks, CI "checks" job)
--
-- The fixture has the shape util_sing-box.lua generates for the routing the
-- First Run Wizard writes (RUSSIA -> Direct, PROXY / QUIC / UDP -> server,
-- Default -> server) with FakeDNS and "Remote DNS: IPv4 only".
-- Covered: input parsing, addresses, the regular expression subset, rule
-- selection and order, the target, "unknown" instead of a guess, DNS rule
-- selection, interception by the firewall settings.

package.path = "root/usr/lib/lua/?.lua;" .. package.path
local X = require "luci.easy_vless.explain"

local pass, fail = 0, 0
local function check(msg, cond)
	if cond then pass = pass + 1 print("PASS: " .. msg)
	else fail = fail + 1 print("FAIL: " .. msg) end
end

-- ---------------------------------------------------------------- fixture
local function wizard_config(opts)
	opts = opts or {}
	local c = {
		inbounds = {
			{ type = "tproxy", tag = "tproxy", listen = "::", listen_port = 1041 },
			{ type = "direct", tag = "dns-in", listen = "127.0.0.1", listen_port = 1042 },
		},
		outbounds = {
			{ type = "vless", tag = "default", server = "fi.example.net", server_port = 443, detour = "direct" },
			{ type = "vless", tag = "PROXY", server = "fi.example.net", server_port = 443, detour = "direct" },
			{ type = "vless", tag = "QUIC", server = "fi.example.net", server_port = 443, detour = "direct" },
			{ type = "vless", tag = "UDP", server = "fi.example.net", server_port = 443, detour = "direct" },
			{ type = "direct", tag = "direct", routing_mark = 255 },
		},
		route = {
			final = "default",
			rules = {
				{ action = "hijack-dns", inbound = "dns-in" },
				{ action = "sniff", inbound = "dns-in" },
				{ action = "sniff", inbound = "tproxy" },
				{ action = "route", outbound = "direct", network = { "tcp", "udp" }, domain_regex = { "\\.ru$" } },
				{ action = "route", outbound = "PROXY", network = { "tcp", "udp" }, domain_keyword = { "youtube.com", "googlevideo.com", "x.com" } },
				{ action = "route", outbound = "QUIC", network = { "udp" }, port = { 443 } },
				{ action = "route", outbound = "UDP", network = { "udp" } },
			},
		},
		dns = {
			final = "remote",
			servers = {
				{ type = "local", tag = "local" },
				{ type = "udp", tag = "direct", server = "192.0.2.53", server_port = 53, detour = "direct" },
				{ type = "udp", tag = "remote", server = "1.1.1.1", server_port = 53, detour = "default", domain_resolver = "direct" },
				{ type = "fakeip", tag = "remote_fakeip", inet4_range = "198.18.0.0/16", inet6_range = "fc00::/18" },
				{ type = "udp", tag = "PROXY", server = "1.1.1.1", server_port = 53, detour = "PROXY", domain_resolver = "direct" },
			},
			rules = {
				{ action = "route", server = "direct", domain = { "fi.example.net" }, disable_cache = false },
				{ action = "predefined", rcode = "NOERROR", domain_regex = { "\\.ru$" }, query_type = { "AAAA" } },
				{ action = "route", server = "direct", domain_regex = { "\\.ru$" }, disable_cache = false },
				{ action = "predefined", rcode = "NOERROR", domain_keyword = { "youtube.com", "googlevideo.com", "x.com" }, query_type = { "AAAA" } },
				{ action = "route", server = "PROXY", domain_keyword = { "youtube.com", "googlevideo.com", "x.com" }, disable_cache = false, client_subnet = "203.0.113.0/24" },
				{ action = "predefined", rcode = "NOERROR", query_type = { "AAAA" } },
				{ server = "remote_fakeip", query_type = { "A" }, disable_cache = true, rewrite_ttl = 1 },
				{ server = "remote", disable_cache = true },
			},
		},
	}
	if opts.redirect then
		c.inbounds = {
			{ type = "redirect", tag = "redirect_tcp", listen = "::", listen_port = 1041 },
			{ type = "tproxy", tag = "tproxy_udp", listen = "::", listen_port = 1041, network = "udp" },
		}
	end
	return c
end
local META = {
	node = "main_router", default_outbound = "default",
	rules = { { index = 4, id = "RUSSIA" }, { index = 5, id = "PROXY" }, { index = 6, id = "QUIC" }, { index = 7, id = "UDP" } },
	outbounds = { default = "srv_fi", PROXY = "srv_fi", QUIC = "srv_fi", UDP = "srv_fi" },
}
local CFG = wizard_config()
local function q(t)
	t.network = t.network or "tcp"
	t.inbound = t.inbound or X.inbound_for(CFG, t.network)
	if t.protocol == nil then t.protocol = X.guess_protocol(t.network, t.port) end
	return t
end
local function codes(reasons)
	local t = {}
	for _, r in ipairs(reasons or {}) do t[#t + 1] = r.code end
	return table.concat(t, ",")
end

-- ---------------------------------------------------------------- input
local function input(text)
	local r, err = X.parse_input(text)
	if not r then return "error:" .. err end
	return r.kind .. ":" .. (r.host or r.ip) .. ":" .. tostring(r.port)
end
check("input: domain", input("youtube.com") == "domain:youtube.com:nil")
check("input: domain is lower-cased, trailing dot removed", input(" YouTube.COM. ") == "domain:youtube.com:nil")
check("input: host:port", input("youtube.com:8443") == "domain:youtube.com:8443")
check("input: URL - port from the scheme, path dropped", input("https://www.youtube.com/watch?v=1") == "domain:www.youtube.com:443" and input("http://example.org/") == "domain:example.org:80")
check("input: URL with a port and credentials", input("https://user:pw@example.org:8443/x") == "domain:example.org:8443")
check("input: IPv4", input("1.2.3.4") == "ip:1.2.3.4:nil" and input("1.2.3.4:53") == "ip:1.2.3.4:53")
check("input: IPv6, bare and bracketed with a port", input("2001:db8::1") == "ip:2001:db8::1:nil" and input("[2001:db8::1]:443") == "ip:2001:db8::1:443")
check("input: empty", input("   ") == "error:empty")
check("input: invalid port", input("example.org:70000") == "error:port")
check("input: not a host name", input("exa mple.org") == "error:invalid" and input("a..b") == "error:invalid" and input("$(reboot)") == "error:invalid" and input("999.1.1.1") == "error:invalid")
check("input: shell metacharacters never pass", input("a.com;id") == "error:invalid" and input("a.com`id`") == "error:invalid" and input("'a.com") == "error:invalid")

-- ---------------------------------------------------------------- addresses
local function inc(ip, cidr) return X.in_cidr(X.parse_ip(ip), cidr) end
check("cidr: IPv4", inc("10.1.2.3", "10.0.0.0/8") and not inc("11.1.2.3", "10.0.0.0/8") and inc("192.168.1.7", "192.168.1.0/24") and not inc("192.168.2.7", "192.168.1.0/24"))
check("cidr: IPv4 host and odd prefix", inc("1.2.3.4", "1.2.3.4") and inc("172.20.0.1", "172.16.0.0/12") and not inc("172.32.0.1", "172.16.0.0/12"))
check("cidr: IPv6", inc("2001:db8::1", "2001:db8::/32") and not inc("2001:db9::1", "2001:db8::/32") and inc("fe80::1", "fe80::/10"))
check("cidr: families do not mix", not inc("1.2.3.4", "::/0") and not inc("2001:db8::1", "0.0.0.0/0"))
check("private: LAN, loopback, link-local - not public addresses", X.is_private(X.parse_ip("192.168.1.1")) and X.is_private(X.parse_ip("127.0.0.1")) and X.is_private(X.parse_ip("fd00::1")) and not X.is_private(X.parse_ip("8.8.8.8")))
check("fake ip range", X.is_fake_ip(X.parse_ip("198.18.3.4")) and not X.is_fake_ip(X.parse_ip("198.19.0.1")))
check("parse_ip: rejects garbage", X.parse_ip("1.2.3") == nil and X.parse_ip("1.2.3.256") == nil and X.parse_ip(":::") == nil and X.parse_ip("example.org") == nil)

-- ---------------------------------------------------------------- regular expressions
local function re(p, s)
	local f = X.re_compile(p)
	if not f then return "unsupported" end
	return f(s)
end
check("regex: \\.ru$ (the RUSSIA resource)", re("\\.ru$", "yandex.ru") == true and re("\\.ru$", "yandex.rus") == false and re("\\.ru$", "ru") == false)
check("regex: a search, not a full match", re("google", "www.google.com") == true and re("^google", "www.google.com") == false)
check("regex: alternation and groups", re("\\.(ru|su|xn--p1ai)$", "site.su") == true and re("\\.(ru|su|xn--p1ai)$", "site.com") == false)
check("regex: classes and repetition", re("^[a-z0-9-]+\\.example\\.org$", "cdn-7.example.org") == true and re("^[a-z0-9-]+\\.example\\.org$", "a.b.example.org") == false)
check("regex: \\d, ?, {m,n}", re("^r\\d{1,2}---sn-.+\\.googlevideo\\.com$", "r5---sn-abc.googlevideo.com") == true and re("^https?$", "http") == true and re("^a{2,3}$", "aaaa") == false)
check("regex: negated class, optional group", re("^[^.]+\\.ru$", "a.b.ru") == false and re("^(www\\.)?example\\.com$", "example.com") == true)
check("regex: (?i) prefix", re("(?i)\\.RU$", "site.ru") == true)
check("regex: unsupported syntax is reported, not guessed", re("\\bfoo", "foo") == "unsupported" and re("(?s).", "a") == "unsupported" and re("\\p{L}+", "a") == "unsupported" and re("a**", "a") == "unsupported")
check("regex: broken expression is reported", re("(abc", "abc") == "unsupported" and re("[abc", "a") == "unsupported")
check("regex: catastrophic backtracking is cut off (unknown), not a hang", re("^(a+)+$", string.rep("a", 40) .. "!") == nil)

-- ---------------------------------------------------------------- rule selection
local r = X.route(CFG, META, q({ host = "www.youtube.com", port = 443 }))
check("youtube.com: the PROXY rule (" .. tostring(r.match.rule_id) .. ")", r.match.kind == "rule" and r.match.rule_id == "PROXY" and r.match.priority == 2)
check("youtube.com: reason = keyword of the rule's domain list", codes(r.match.reasons) == "domain_keyword" and r.match.reasons[1].item == "youtube.com")
check("youtube.com: target = the server behind the PROXY outbound", r.match.target.kind == "server" and r.match.target.id == "srv_fi" and r.match.target.tag == "PROXY")
check("youtube.com: certain, RUSSIA was checked first and skipped", r.certain and #r.possible == 0 and #r.skipped == 1 and r.skipped[1].rule_id == "RUSSIA" and r.skipped[1].why.code == "domain_no_match")

r = X.route(CFG, META, q({ host = "yandex.ru", port = 443 }))
check("yandex.ru: RUSSIA -> Direct", r.match.rule_id == "RUSSIA" and r.match.priority == 1 and r.match.target.kind == "direct" and codes(r.match.reasons) == "domain_regex")
check("yandex.ru: nothing before it", #r.skipped == 0 and r.certain)

r = X.route(CFG, META, q({ host = "example.org", port = 443 }))
check("example.org over TCP: no rule, Default", r.match.kind == "default" and r.match.target.kind == "server" and r.match.target.id == "srv_fi" and r.match.target.tag == "default")
check("example.org: every rule listed with the reason it does not apply",
	#r.skipped == 4 and r.skipped[1].why.code == "domain_no_match" and r.skipped[3].rule_id == "QUIC" and r.skipped[3].why.code == "network" and r.skipped[4].why.code == "network")

r = X.route(CFG, META, q({ host = "example.org", port = 443, network = "udp" }))
check("example.org over UDP 443: the QUIC rule, before UDP", r.match.rule_id == "QUIC" and codes(r.match.reasons) == "network,port" and r.match.priority == 3)
r = X.route(CFG, META, q({ host = "example.org", port = 3478, network = "udp" }))
check("example.org over UDP 3478: QUIC skipped (port), the UDP rule", r.match.rule_id == "UDP" and r.skipped[#r.skipped].rule_id == "QUIC" and r.skipped[#r.skipped].why.code == "port")
r = X.route(CFG, META, q({ host = "yandex.ru", port = 443, network = "udp" }))
check("order: RUSSIA is above QUIC, so yandex.ru over QUIC stays Direct", r.match.rule_id == "RUSSIA")

r = X.route(CFG, META, q({ ips = { "8.8.8.8" }, port = 443 }))
check("IP only: domain rules cannot match (no domain), Default", r.match.kind == "default" and r.skipped[1].why.code == "no_domain" and r.certain)

-- rule order decides: the same domain in two rules
local c2 = wizard_config()
table.insert(c2.route.rules, 4, { action = "route", outbound = "direct", domain_suffix = { "youtube.com" } })
local m2 = { rules = { { index = 4, id = "MYDIRECT" }, { index = 5, id = "RUSSIA" }, { index = 6, id = "PROXY" } }, outbounds = META.outbounds }
r = X.route(c2, m2, q({ host = "www.youtube.com", port = 443 }))
check("two matching rules: the first one wins", r.match.rule_id == "MYDIRECT" and r.match.target.kind == "direct" and r.match.reasons[1].code == "domain_suffix")
check("domain_suffix: the domain and its subdomains, not a longer name", X.match_rule({ domain_suffix = { "youtube.com" } }, { host = "youtube.com" }) == "yes"
	and X.match_rule({ domain_suffix = { "youtube.com" } }, { host = "m.youtube.com" }) == "yes" and X.match_rule({ domain_suffix = { "youtube.com" } }, { host = "notyoutube.com" }) == "no")
check("domain (full): exact only", X.match_rule({ domain = { "example.org" } }, { host = "www.example.org" }) == "no" and X.match_rule({ domain = { "Example.org" } }, { host = "example.org" }) == "yes")

-- conditions combine: all groups must match, destination items are alternatives
local combo = { domain_suffix = { "example.org" }, ip_cidr = { "10.0.0.0/8" }, port = { 443 }, network = { "tcp" } }
check("groups: domain OR ip, AND port, AND network", X.match_rule(combo, { host = "a.example.org", port = 443, network = "tcp" }) == "yes"
	and X.match_rule(combo, { ips = { "10.9.9.9" }, port = 443, network = "tcp" }) == "yes"
	and X.match_rule(combo, { host = "a.example.org", port = 80, network = "tcp" }) == "no"
	and X.match_rule(combo, { host = "a.example.org", port = 443, network = "udp" }) == "no")
check("port ranges", X.match_rule({ port_range = { "1000:2000" } }, { port = 1500 }) == "yes" and X.match_rule({ port_range = { "1000:2000" }, port = { 80 } }, { port = 80 }) == "yes"
	and X.match_rule({ port_range = { "1000:2000" } }, { port = 2001 }) == "no")
check("invert", X.match_rule({ domain = { "a.org" }, invert = true }, { host = "b.org" }) == "yes" and X.match_rule({ domain = { "a.org" }, invert = true }, { host = "a.org" }) == "no")
check("inbound", X.match_rule({ inbound = { "socks-in" } }, { inbound = "tproxy" }) == "no" and X.match_rule({ inbound = { "tproxy", "socks-in" } }, { inbound = "tproxy" }) == "yes")
check("source", X.match_rule({ source_ip_cidr = { "192.168.1.50/32" } }, { source = "192.168.1.50" }) == "yes" and X.match_rule({ source_ip_cidr = { "192.168.1.50/32" } }, { source = "192.168.1.51" }) == "no"
	and X.match_rule({ source_ip_is_private = true }, { source = "192.168.1.51" }) == "yes")

-- ---------------------------------------------------------------- unknown is reported, never guessed
local res, why = X.match_rule({ ip_cidr = { "8.8.8.0/24" } }, { host = "dns.google" })
check("IP rule for a domain without a known address: unknown", res == "unknown" and why[1].code == "ip_unknown")
check("IP rule for a domain with resolved addresses: evaluated", X.match_rule({ ip_cidr = { "8.8.8.0/24" } }, { host = "dns.google", ips = { "8.8.4.4", "8.8.8.8" } }) == "yes"
	and X.match_rule({ ip_cidr = { "8.8.8.0/24" } }, { host = "dns.google", ips = { "8.8.4.4" } }) == "no")
check("IP rule against the FakeDNS address the client really connects to", X.match_rule({ ip_cidr = { "8.8.8.0/24" } }, { host = "dns.google", ips = { "198.18.0.7" } }) == "no")
res, why = X.match_rule({ rule_set = { "geosite-netflix" } }, { host = "netflix.com" })
check("geodata rule-set: unknown", res == "unknown" and why[1].code == "rule_set" and why[1].item == "geosite-netflix")
res, why = X.match_rule({ source_ip_cidr = { "192.168.1.0/24" } }, { host = "a.org" })
check("source condition without a source address: unknown", res == "unknown" and why[1].code == "source_unknown")
res, why = X.match_rule({ protocol = { "bittorrent" } }, { host = "a.org", network = "tcp", port = 6881 })
check("sniffed protocol that cannot be assumed: unknown", res == "unknown" and why[1].code == "protocol_unknown")
check("sniffed protocol assumed from the port", X.guess_protocol("tcp", 443) == "tls" and X.guess_protocol("udp", 443) == "quic" and X.guess_protocol("tcp", 80) == "http" and X.guess_protocol("tcp", 8443) == nil)
res, why = X.match_rule({ domain_regex = { "\\bfoo" } }, { host = "foo.org" })
check("unsupported regular expression: unknown", res == "unknown" and why[1].code == "regex_unsupported")
check("a definite 'no' beats an unknown (port does not match)", X.match_rule({ rule_set = { "geoip-ru" }, port = { 80 } }, { host = "a.org", port = 443 }) == "no")
check("a matching domain beats an unknown item of the same group", X.match_rule({ rule_set = { "geosite-x" }, domain = { "a.org" } }, { host = "a.org" }) == "yes")

local c3 = wizard_config()
table.insert(c3.route.rules, 4, { action = "route", outbound = "direct", rule_set = { "geoip-ru" } })
local m3 = { rules = { { index = 4, id = "GEO" }, { index = 5, id = "RUSSIA" }, { index = 6, id = "PROXY" } }, outbounds = META.outbounds }
r = X.route(c3, m3, q({ host = "www.youtube.com", port = 443 }))
check("an unknown rule before the match: the answer is marked uncertain and names it",
	r.certain == false and #r.possible == 1 and r.possible[1].rule_id == "GEO" and r.possible[1].target.kind == "direct" and r.match.rule_id == "PROXY")

-- ---------------------------------------------------------------- targets
local c4 = wizard_config()
c4.outbounds[1] = { type = "urltest", tag = "urltest-grp1", outbounds = { "ut-a", "ut-b" }, url = "https://x.com" }
table.insert(c4.outbounds, { type = "vless", tag = "ut-a", server = "a.example.net", server_port = 443 })
table.insert(c4.outbounds, { type = "vless", tag = "ut-b", server = "b.example.net", server_port = 443 })
c4.route.final = "urltest-grp1"
r = X.route(c4, { rules = META.rules, outbounds = { ["ut-a"] = "srv_a", ["ut-b"] = "srv_b", PROXY = "srv_fi" } }, q({ host = "example.org", port = 443 }))
check("target: URL Test group with its servers", r.match.target.kind == "group" and r.match.target.id == "grp1" and #r.match.target.members == 2 and r.match.target.members[2].id == "srv_b")
local c5 = wizard_config()
c5.route.final = nil
table.insert(c5.route.rules, { action = "reject" })
r = X.route(c5, META, q({ host = "example.org", port = 443 }))
check("target: Default = Block (generated as a final reject rule)", r.match.target.kind == "block" and r.match.action == "reject")
check("target: an outbound that is not in the configuration is 'unknown', not invented", X.describe_outbound(CFG, META, "nope").kind == "unknown")
c5 = wizard_config()
c5.route.final = "direct"
r = X.route(c5, META, q({ host = "example.org", port = 443 }))
check("target: Default = Direct", r.match.kind == "default" and r.match.target.kind == "direct")

-- REDIRECT mode: TCP arrives on redirect_tcp, UDP on tproxy_udp
local cr = wizard_config({ redirect = true })
check("inbound: TPROXY mode", X.inbound_for(CFG, "tcp") == "tproxy" and X.inbound_for(CFG, "udp") == "tproxy")
check("inbound: REDIRECT mode", X.inbound_for(cr, "tcp") == "redirect_tcp" and X.inbound_for(cr, "udp") == "tproxy_udp")

-- ---------------------------------------------------------------- DNS
local d = X.dns(CFG, META, "www.youtube.com", "A")
check("DNS youtube.com A: remote DNS of the PROXY rule, through the proxy", d.match.server.kind == "remote" and d.match.server.tag == "PROXY" and d.match.server.detour.kind == "server" and d.match.server.detour.id == "srv_fi")
check("DNS youtube.com A: protocol, address, EDNS client subnet", d.match.server.type == "udp" and d.match.server.address == "1.1.1.1" and d.match.client_subnet == "203.0.113.0/24")
d = X.dns(CFG, META, "www.youtube.com", "AAAA")
check("DNS youtube.com AAAA: suppressed (IPv4 only)", d.match.action == "predefined" and d.match.server == nil)
d = X.dns(CFG, META, "yandex.ru", "A")
check("DNS yandex.ru A: Direct DNS, sent directly", d.match.server.kind == "direct" and d.match.server.address == "192.0.2.53" and d.match.server.detour.kind == "direct")
d = X.dns(CFG, META, "example.org", "A")
check("DNS example.org A: FakeDNS", d.match.server.kind == "fakeip" and d.match.server.range4 == "198.18.0.0/16" and d.certain)
d = X.dns(CFG, META, "example.org", "TXT")
check("DNS example.org TXT: FakeDNS answers only A/AAAA - Remote DNS", d.match.server.kind == "remote" and d.match.server.tag == "remote" and d.match.server.detour.id == "srv_fi")
d = X.dns(CFG, META, "fi.example.net", "A")
check("DNS of the server's own name: Direct DNS", d.match.server.kind == "direct" and d.match.index == 1)
local c6 = wizard_config()
c6.dns.rules = {}
c6.dns.final = "direct"
d = X.dns(c6, META, "example.org", "A")
check("DNS without rules: dns.final", d.match.kind == "final" and d.match.server.kind == "direct")
c6 = wizard_config()
c6.dns.servers[3].detour = "direct"
check("Remote DNS with 'route: direct'", X.describe_dns_server(c6, META, "remote").kind == "remote" and X.describe_dns_server(c6, META, "remote").detour.kind == "direct")

-- ---------------------------------------------------------------- interception
local S = { tcp_proxy_way = "tproxy", tcp_redir_ports = "1:65535", udp_redir_ports = "1:65535", ipv6_tproxy = "0", client_proxy = "1", localhost_proxy = "1" }
local function with(t) local o = {} for k, v in pairs(S) do o[k] = v end for k, v in pairs(t) do o[k] = v end return o end
local i = X.interception(S, { network = "tcp", port = 443 })
check("interception: TCP, TPROXY", i.intercepted == "yes" and i.method == "tproxy")
i = X.interception(with({ tcp_proxy_way = "redirect" }), { network = "tcp", port = 443 })
check("interception: TCP REDIRECT mode", i.intercepted == "yes" and i.method == "redirect")
i = X.interception(with({ tcp_proxy_way = "redirect" }), { network = "udp", port = 443 })
check("interception: UDP is always TPROXY", i.method == "tproxy")
i = X.interception(with({ tcp_redir_ports = "80,443" }), { network = "tcp", port = 8443, ips = { "8.8.8.8" } })
check("interception: port outside the redirected ports - not intercepted", i.intercepted == "no" and i.reasons[1].code == "port_not_redirected" and i.reasons[1].ports == "80,443")
i = X.interception(with({ tcp_redir_ports = "80,443" }), { network = "tcp", port = 8443, fake = true })
check("interception: a FakeDNS address is redirected on every port", i.intercepted == "yes" and i.reasons[1].code == "fake_ip")
i = X.interception(with({ udp_no_redir_ports = "500,4500" }), { network = "udp", port = 4500 })
check("interception: excluded port", i.intercepted == "no" and i.reasons[1].code == "no_redir_port")
i = X.interception(with({ udp_no_redir_ports = "disable" }), { network = "udp", port = 4500 })
check("interception: no_redir_ports 'disable' excludes nothing", i.intercepted == "yes")
i = X.interception(S, { network = "tcp", port = 80, ips = { "192.168.1.10" } })
check("interception: LAN address - not intercepted", i.intercepted == "no" and i.reasons[1].code == "private_ip")
i = X.interception(S, { network = "tcp", port = 443, ips = { "2001:db8::1" } })
check("interception: IPv6 destination with IPv6 TProxy off", i.intercepted == "no" and i.reasons[1].code == "ipv6_off")
i = X.interception(with({ ipv6_tproxy = "1" }), { network = "tcp", port = 443, ips = { "2001:db8::1" } })
check("interception: IPv6 destination with IPv6 TProxy on", i.intercepted == "yes")
i = X.interception(with({ client_proxy = "0", localhost_proxy = "0" }), { network = "tcp", port = 443 })
check("interception: Client Proxy and Localhost Proxy off", i.intercepted == "no" and i.reasons[1].code == "proxy_off")
i = X.interception(with({ client_proxy = "0" }), { network = "tcp", port = 443 })
check("interception: only the router's own traffic", i.intercepted == "yes" and i.lan == false and i.router == true)
check("ports_cover: lists and ranges", X.ports_cover("80,443,1000:2000", 1500) and X.ports_cover("1:65535", 7) and not X.ports_cover("80,443", 81) and X.ports_cover("", 5))

-- 1.0: a rule with something this module does not evaluate is "unknown", never a silent match
do
	local cfg = { outbounds = { { type = "direct", tag = "direct" }, { type = "vless", tag = "srv" } },
		route = { final = "direct", rules = {
			{ action = "route", outbound = "srv", type = "logical", mode = "and", rules = { { network = "udp" }, { port = 443 } } },
			{ action = "route", outbound = "srv", domain_suffix = { "example.org" } } } },
		dns = { servers = { { tag = "direct", type = "udp", server = "192.0.2.53" }, { tag = "remote", type = "udp", server = "1.1.1.1", detour = "srv" } },
			final = "direct", rules = { { action = "route", server = "remote", ip_accept_any = true } } } }
	local res = X.route(cfg, {}, { host = "example.org", port = 443, network = "tcp", inbound = "tproxy" })
	check("a logical rule is not taken for a rule without conditions: unknown, the answer is not certain",
		res.certain == false and #res.possible == 1 and res.possible[1].reasons[1].code == "unsupported" and res.possible[1].reasons[1].item == "mode")
	check("the rule after it is still evaluated", res.match.kind == "rule" and res.match.index == 2 and res.match.target.kind == "server")
	local d = X.dns(cfg, {}, "example.org", "A")
	check("a DNS rule with a condition that is not evaluated: unknown, DNS not certain",
		d.certain == false and #d.possible == 1 and d.possible[1].reasons[1].code == "unsupported" and d.possible[1].reasons[1].item == "ip_accept_any" and d.match.kind == "final")
	local y, why = X.match_rule({ action = "route", outbound = "srv", network = { "tcp" }, clash_mode = "global" }, { network = "udp" })
	check("a rule that does not match for a known reason stays 'no' (the unknown part cannot change that)", y == X.NO and why[1].code == "network")
end

print(string.format("\n===== Route Explain: %d passed, %d failed =====", pass, fail))
os.exit(fail == 0 and 0 or 1)
