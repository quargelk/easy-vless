'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require poll';
'require easy_vless.common as ev';

/*
 * Easy VLESS - Diagnostics (0.9.0).
 *   Connection        one panel: Core, DNS, nftables, TPROXY, VLESS, Routing,
 *                     Internet - each with its checks and the concrete reason
 *   Route Explain     where a connection to a domain / IP goes and why
 *   DNS               how one domain is resolved, and what is wrong if not
 *   Forwarding        nftables, policy routing, TPROXY / REDIRECT
 *
 * Everything shown here is computed on the router by rpcd "diag" (diag.lua):
 * Route Explain evaluates the route and DNS rules of the generated sing-box
 * configuration (explain.lua), the diagnostics read the real nftables / ip
 * rule state and DNS answers (diagnose.lua). This view only turns the result
 * codes into text; what the router could not determine is shown as such.
 * All requests are read-only: nothing is started, stopped or saved.
 */

const CONFIG = ev.CONFIG;

const MARK = {
	ok: [ '✅', 'ok' ],
	warn: [ '⚠️', 'warn' ],
	fail: [ '❌', 'bad' ],
	off: [ '⏸', 'idle' ],
	info: [ 'ℹ️', 'info' ]
};

function ms(v) {
	return (v != null) ? ' · ' + _('%d ms').format(v) : '';
}

/* "5 min ago" for an age in seconds measured on the router */
function ageText(age) {
	if (age == null)
		return '';
	if (age < 60)
		return ' · ' + _('just now');
	if (age < 3600)
		return ' · ' + _('%d min ago').format(Math.floor(age / 60));
	if (age < 86400)
		return ' · ' + _('%d h ago').format(Math.floor(age / 3600));
	return ' · ' + _('%d d ago').format(Math.floor(age / 86400));
}

function list(v) {
	return ev.arr(v).join(', ');
}

/* ---------- names ---------- */

function targetText(t) {
	if (!t)
		return _('unknown');
	switch (t.kind) {
	case 'direct':
		return _('Direct');
	case 'block':
		return _('Block');
	case 'server':
		return 'VLESS: ' + (t.name || t.id || t.tag);
	case 'group': {
		let s = _('URL Test group') + ': ' + (t.name || t.id || t.tag);
		if (t.now)
			s += ' → ' + _('now using %s').format(t.now.name) + (t.now.delay > 0 ? ' (' + _('%d ms').format(t.now.delay) + ')' : '');
		else if (ev.arr(t.members).length)
			s += ' (' + ev.arr(t.members).map(function(m) { return m.name || m.id || m.tag; }).join(', ') + ')';
		return s;
	}
	}
	return _('unknown outbound "%s" (not part of the configuration)').format(t.tag || '?');
}

function dnsServerText(s) {
	if (!s)
		return _('unknown');
	const addr = s.address ? (s.type || '') + '://' + s.address + (s.port ? ':' + s.port : '') + (s.path || '') : '';
	switch (s.kind) {
	case 'direct':
		return _('Direct DNS') + (addr ? ' (' + addr + ')' : '');
	case 'remote':
		return _('Remote DNS') + (addr ? ' (' + addr + ')' : '');
	case 'fakeip':
		return _('FakeDNS (placeholder address %s)').format(s.range4 || '198.18.0.0/16');
	case 'local':
		return _('the router\'s system resolver');
	case 'hosts':
		return _('fixed address (DNS hosts)');
	case 'other':
		return (s.tag || '') + (addr ? ' (' + addr + ')' : '');
	}
	return _('unknown DNS server "%s"').format(s.tag || '?');
}

function dnsRouteText(s) {
	if (!s || !s.detour)
		return '';
	return s.detour.kind == 'direct' ? _('directly, without the proxy') : _('through the proxy: %s').format(targetText(s.detour));
}

/* ---------- Route Explain: reasons ---------- */

function originText(o) {
	if (!o)
		return '';
	return o.kind == 'resource' ? ' — ' + _('from the resource %s').format(o.name) : ' — ' + _('from the rule\'s own domain list');
}

/* why a rule matched */
function reasonText(r) {
	switch (r.code) {
	case 'domain':
		return _('the domain is listed exactly: %s').format(r.item) + originText(r.origin);
	case 'domain_suffix':
		return _('the domain belongs to %s (domain and subdomains)').format(r.item) + originText(r.origin);
	case 'domain_keyword':
		return _('the domain name contains "%s"').format(r.item) + originText(r.origin);
	case 'domain_regex':
		return _('the domain matches the regular expression %s').format(r.item) + originText(r.origin);
	case 'ip_cidr':
		return _('the address %s is in %s').format(r.ip || '', r.item);
	case 'ip_is_private':
		return _('the address %s is a private / local address').format(r.item);
	case 'network':
		return _('network is %s').format(String(r.value).toUpperCase());
	case 'port':
		return _('destination port %s is in %s').format(r.value, r.item);
	case 'protocol':
		return _('sniffed protocol is %s').format(String(r.value).toUpperCase());
	case 'source':
		return _('source address %s matches %s').format(r.value, r.item);
	case 'source_port':
		return _('source port %s matches').format(r.value);
	case 'inbound':
		return _('arrives on the inbound %s').format(r.value);
	case 'invert':
		return _('the rule is inverted and its conditions do not match');
	}
	return r.code;
}

/* why a rule did not match */
function skipText(w) {
	if (!w)
		return _('its conditions do not match');
	switch (w.code) {
	case 'no_domain':
		return _('it matches domains, and for an IP address no domain name is known');
	case 'domain_no_match':
		return _('the domain is not in its lists');
	case 'ip_no_match':
		return _('the address is not in its IP list');
	case 'network':
		return _('it is for %s, the connection is %s').format(String(w.item).toUpperCase(), String(w.value).toUpperCase());
	case 'port':
		return _('it is for port %s, the connection uses port %s').format(w.item, w.value);
	case 'protocol':
		return _('it is for the protocol %s, the connection is %s').format(String(w.item).toUpperCase(), String(w.value).toUpperCase());
	case 'source':
		return _('the source address %s is not in its source list').format(w.value);
	case 'source_port':
		return _('the source port %s is not in its list').format(w.value);
	case 'inbound':
		return _('it is for the inbound %s').format(w.item);
	case 'invert':
		return _('it is inverted and its conditions match');
	}
	return _('its conditions do not match');
}

/* why a rule could not be evaluated */
function unknownText(r) {
	switch (r.code) {
	case 'rule_set':
		return _('it uses geodata (%s), which Route Explain cannot read').format(r.item);
	case 'regex_unsupported':
		return _('its regular expression %s is too complex to evaluate here').format(r.item);
	case 'ip_unknown':
		return _('it matches IP addresses, and the address of this domain could not be determined');
	case 'protocol_unknown':
		return _('it matches the sniffed protocol (%s), which is not known for this port').format(String(r.item).toUpperCase());
	case 'port_unknown':
		return _('it matches a port and no port was given');
	case 'source_unknown':
		return _('it matches a source address and none was given (enter one under "More")');
	case 'source_port_unknown':
		return _('it matches a source port, which is not known in advance');
	}
	return r.code;
}

function interceptText(i) {
	const method = i.method == 'redirect' ? 'REDIRECT' : 'TPROXY';
	const r = ev.arr(i.reasons)[0] || {};
	if (i.intercepted == 'no') {
		switch (r.code) {
		case 'proxy_off':
			return _('Not intercepted: Client Proxy and Localhost Proxy are both off (Main). The connection leaves the router directly; the rules are not applied.');
		case 'no_redir_port':
			return _('Not intercepted: port %s is in the "no proxy" ports (%s). The connection leaves the router directly; the rules are not applied.').format(r.port, r.ports);
		case 'port_not_redirected':
			return _('Not intercepted: port %s is outside the redirected ports (%s, Settings → Forwarding). The connection leaves the router directly; the rules are not applied.').format(r.port, r.ports);
		case 'private_ip':
			return _('Not intercepted: %s is a local / private address. It never reaches Easy VLESS.').format(r.ip);
		case 'ipv6_off':
			return _('Not intercepted: the destination is IPv6 and IPv6 TProxy is off (Settings → Forwarding). The connection leaves the router directly.');
		}
		return _('Not intercepted by the firewall.');
	}
	let s = method;
	if (r.code == 'fake_ip')
		s += ' — ' + _('the device connects to a FakeDNS address, which is redirected on every port');
	else if (i.intercepted == 'unknown')
		s += ' — ' + _('only for the redirected ports (%s)').format(r.ports || '');
	if (!i.lan)
		s += ' · ' + _('only the router\'s own traffic (Client Proxy is off)');
	else if (!i.router)
		s += ' · ' + _('only LAN devices (Localhost Proxy is off)');
	return s;
}

function inputError(reason) {
	switch (reason) {
	case 'empty':
		return _('Enter a domain, an IP address, host:port or a URL.');
	case 'port':
		return _('The port must be between 1 and 65535.');
	case 'source':
		return _('The source must be an IP address.');
	case 'not_domain':
		return _('Enter a domain name (DNS diagnostics is about names, not addresses).');
	}
	return _('This is not a valid domain or IP address.');
}

function requestError(res) {
	if (res.rpc_error)
		return _('The router did not answer: %s').format(res.error);
	switch (res.error) {
	case 'input':
		return inputError(res.reason);
	case 'busy':
		return _('Easy VLESS is busy with another operation (start, stop, check or a server test). Try again in a few seconds.');
	case 'config':
		return _('The sing-box configuration could not be generated from the saved settings: %s').format(res.detail || '');
	case 'interrupted':
		return _('The diagnostic was interrupted (Easy VLESS was started or stopped meanwhile). Run it again.');
	case 'not_installed':
		return _('The diagnostics are not installed on the router (update the easy-vless package).');
	}
	return _('The diagnostic failed on the router: %s').format(res.detail || res.error || '?');
}

/* ---------- Route Explain: rows [{ label, text, kind, sub }] ---------- */

function ruleName(e) {
	return e.rule_name || e.rule_id || _('rule %d of the configuration').format(e.index);
}

function explainRows(res) {
	const rows = [];
	const inp = res.input;
	const m = res.route.match;

	let what = (inp.kind == 'domain' ? _('domain') : _('IP address')) + ' · ' + inp.network.toUpperCase() + ' · ' +
		(inp.port_assumed ? _('port %s (assumed)').format(inp.port) : _('port %s').format(inp.port));
	if (inp.protocol)
		what += ' · ' + (inp.protocol_assumed ? _('%s (assumed from the port)').format(inp.protocol.toUpperCase()) : inp.protocol.toUpperCase());
	if (inp.source)
		what += ' · ' + _('from %s').format(inp.source);
	rows.push({ id: 'input', label: _('Checked', 'diagnostics'), text: (inp.host || inp.ip), sub: [ what ] });

	const intercepted = res.intercept.intercepted != 'no';
	if (m.kind == 'rule')
		rows.push({ id: 'rule', label: _('Rule', 'diagnostics'), text: ruleName(m) + (m.priority ? ' (' + _('priority %d').format(m.priority) + ')' : ''),
			kind: 'ok' });
	else
		rows.push({ id: 'rule', label: _('Rule', 'diagnostics'), text: _('no rule matches: Default'), kind: 'info' });

	if (m.kind == 'rule')
		rows.push({ id: 'reason', label: _('Reason', 'diagnostics'), text: ev.arr(m.reasons).map(reasonText).join('; ') || _('the rule has no conditions (it matches everything)') });
	else
		rows.push({ id: 'reason', label: _('Reason', 'diagnostics'), text: _('traffic that matches no rule goes to the Default target') });

	rows.push({ id: 'target', label: _('Target', 'routing target'), text: targetText(m.target),
		kind: m.target && m.target.kind == 'unknown' ? 'bad' : null });

	if (res.dns) {
		const a = res.dns.a.match, a6 = res.dns.aaaa.match;
		const sub = [];
		let text;
		if (a.action == 'predefined')
			text = _('answered empty (blocked by a DNS rule)');
		else {
			text = dnsServerText(a.server);
			if (a.server && a.server.kind == 'fakeip')
				sub.push(_('The device gets a placeholder address; the real name is resolved by the proxy server.'));
		}
		if (a.client_subnet)
			sub.push(_('EDNS Client Subnet: %s').format(a.client_subnet));
		sub.push(a6.action == 'predefined' ? _('IPv6 (AAAA): not answered - IPv4 only') : _('IPv6 (AAAA): %s').format(dnsServerText(a6.server)));
		if (res.dns.a.certain === false)
			sub.push(_('Not certain: a DNS rule with geodata could apply first.'));
		rows.push({ id: 'dns', label: _('DNS', 'diagnostics'), text: text, sub: sub });
		if (a.action != 'predefined' && a.server && a.server.kind != 'fakeip' && dnsRouteText(a.server))
			rows.push({ id: 'dns_route', label: _('DNS route', 'diagnostics'), text: dnsRouteText(a.server) });
	}
	if (res.resolved)
		rows.push({ id: 'resolved', label: _('Resolved', 'diagnostics'), text: res.resolved.status == 'ok'
			? list(res.resolved.addresses) + ' — ' + _('asked the router\'s DNS, because a rule depends on the address')
			: _('the router\'s DNS did not resolve the name (%s); rules that depend on the address stay undecided').format(res.resolved.status) });

	rows.push({ id: 'forwarding', label: _('Forwarding', 'diagnostics'), text: interceptText(res.intercept), kind: intercepted ? null : 'warn' });

	const possible = ev.arr(res.route.possible);
	if (possible.length)
		rows.push({ id: 'uncertain', label: _('Not certain', 'diagnostics'), kind: 'warn',
			text: _('A rule above could apply first; Route Explain cannot decide it:'),
			sub: possible.map(function(e) {
				return '%s → %s: %s'.format(ruleName(e), targetText(e.target), ev.arr(e.reasons).map(unknownText).join('; '));
			}) });

	const skipped = ev.arr(res.route.skipped);
	if (skipped.length)
		rows.push({ id: 'skipped', label: _('Checked before', 'diagnostics'), text: _('%d rule(s) with a higher priority do not apply:').format(skipped.length),
			sub: skipped.map(function(e) { return '%s — %s'.format(e.rule_name || e.rule_id, skipText(e.why)); }) });

	rows.push({ id: 'config', label: _('Based on', 'diagnostics'), text: res.config.source == 'running'
		? _('the configuration sing-box is running with right now')
		: _('the saved settings (Easy VLESS is stopped: this is what a start would use)') });
	return rows;
}

/* ---------- diagnostics: check titles and texts ---------- */

function checkTitle(id) {
	switch (id) {
	case 'fw4': return _('Firewall (fw4 / nft)');
	case 'table': return _('nft table inet easy_vless');
	case 'chains': return _('Easy VLESS chains');
	case 'sets': return _('Address sets');
	case 'policy': return _('Policy routing (fwmark)');
	case 'tcp': return _('TCP forwarding');
	case 'udp': return _('UDP forwarding');
	case 'lan': return _('LAN interception');
	case 'router': return _('Router interception');
	case 'ipv6': return _('IPv6 TProxy');
	case 'exceptions': return _('Port exceptions');
	case 'ports': return _('Redirected ports');
	case 'dns_redirect': return _('DNS redirect (port 53)');
	case 'service': return _('Easy VLESS DNS');
	case 'resolve': return _('Resolution');
	case 'server': return _('DNS used');
	case 'fakedns': return _('FakeDNS');
	case 'ipmode': return _('IPv4 / IPv6 mode');
	case 'direct_dns': return _('Direct DNS');
	case 'remote_dns': return _('Remote DNS');
	case 'hijack': return _('DNS of LAN devices');
	case 'client_dns': return _('Secure DNS on devices');
	case 'ecs': return _('EDNS Client Subnet');
	case 'binary': return _('sing-box');
	case 'environment': return _('Start requirements');
	case 'process': return _('Service');
	case 'node': return _('Selected node');
	case 'test': return _('Server Test');
	case 'references': return _('Targets');
	case 'rules': return _('Rules', 'diagnostics');
	case 'config': return _('Running configuration');
	case 'https': return _('HTTPS request');
	}
	return id;
}

function lookupReason(reason, rcode) {
	switch (reason) {
	case 'timeout': return _('no answer (timeout)');
	case 'nxdomain': return _('the name does not exist (NXDOMAIN)');
	case 'servfail': return _('the DNS server could not resolve it (SERVFAIL: its upstream did not answer)');
	case 'refused': return _('the DNS server refused the query');
	case 'noanswer': return _('answered, but without an address');
	}
	return rcode || _('unexpected answer');
}

function checkText(c) {
	switch (c.code) {
	/* nftables / forwarding */
	case 'fw4_ok': return _('fw4 and nft are available.');
	case 'fw4_missing': return _('fw4 or nft was not found. Easy VLESS needs OpenWrt firewall4 (nftables).');
	case 'nft_unavailable': return _('nft could not list the table: %s').format(c.detail);
	case 'stopped': return _('Easy VLESS is stopped; nothing is loaded.');
	case 'table_leftover': return _('Easy VLESS is stopped, but its nft table is still loaded (left over from a previous run). Press Stop on Main to remove it.');
	case 'policy_leftover': return _('Easy VLESS is stopped, but its ip rule / routing table 998 is still there. Press Stop on Main to remove it.');
	case 'table_missing': return _('sing-box is running, but the nft table inet easy_vless does not exist: no traffic is redirected. Restart Easy VLESS (Save & Apply on Main).');
	case 'table_ok': return _('Loaded.');
	case 'chains_missing': return _('Missing chain(s): %s. Restart Easy VLESS; if it stays, see the log on Main.').format(c.items);
	case 'chains_ok': return _('All %d chains are present.').format(c.count);
	case 'sets_missing': return _('Missing set(s): %s. Restart Easy VLESS.').format(c.items);
	case 'direct_set_empty': return _('The set of direct (local) addresses is empty: connections to LAN addresses would be sent to the proxy. Restart Easy VLESS.');
	case 'sets_ok': return _('Present (direct addresses: %d, server addresses: %d).').format(c.direct, c.vps);
	case 'policy_ok': return _('Packets marked %s are delivered to sing-box (ip rule → table %s).').format(c.mark, c.table);
	case 'policy_rule_missing': return _('The ip rule for fwmark %s (table %s) is missing: redirected packets never reach sing-box. Restart Easy VLESS.').format(c.mark, c.table);
	case 'policy_route_missing': return _('Routing table %s has no local route: redirected packets never reach sing-box. Restart Easy VLESS.').format(c.table);
	case 'proto_off': return _('%s forwarding is switched off (redirected ports: disabled, Settings → Forwarding).').format(c.proto);
	case 'proxy_off': return _('Client Proxy and Localhost Proxy are off: %s is not redirected.').format(c.proto);
	case 'redirect_rule_missing': return _('No %s rule for %s in the chain %s: %s traffic is not redirected. Restart Easy VLESS.').format(c.method, c.proto, c.chain, c.proto);
	case 'redirect_port_mismatch': return _('The %s rule redirects to port %s, but sing-box listens on %s. Restart Easy VLESS.').format(c.proto, c.rule_port, c.port);
	case 'redirect_ok': return _('%s to sing-box port %s.').format(c.method, c.port) + (c.ports ? ' ' + _('Only ports %s.').format(c.ports) : '');
	case 'lan_ok': return _('Traffic of LAN devices is handed to Easy VLESS.');
	case 'lan_off': return _('Client Proxy is off (Main): LAN devices bypass Easy VLESS.');
	case 'lan_jump_missing': return _('The forwarding chain is not hooked into %s: traffic of LAN devices is not redirected. Restart Easy VLESS.').format(c.chain);
	case 'router_ok': return _('Traffic of the router itself is handed to Easy VLESS.');
	case 'router_off': return _('Localhost Proxy is off (Main): the router\'s own traffic bypasses Easy VLESS.');
	case 'router_jump_missing': return _('The output chain is not hooked into %s: the router\'s own traffic is not redirected. Restart Easy VLESS.').format(c.chain);
	case 'ipv6_off': return _('Off (Settings → Forwarding): IPv6 connections bypass Easy VLESS.');
	case 'ipv6_ok': return _('IPv6 traffic is redirected.');
	case 'ipv6_broken': return _('IPv6 TProxy is on, but %s is missing: IPv6 traffic is not redirected. Restart Easy VLESS.').format(c.what);
	case 'port_exceptions': return _('Never proxied: %s.').format(c.items);
	case 'ports_limited': return _('Only these ports are redirected, everything else goes directly: %s.').format(c.items);
	case 'dns_redirect_ok': return _('DNS queries (port 53) are redirected to the DNS of Easy VLESS.');
	case 'dns_redirect_missing': return _('DNS redirect is on, but its rule is missing: devices that use their own DNS server bypass the DNS of Easy VLESS. Restart Easy VLESS.');
	case 'dns_redirect_off': return _('Off (Settings → DNS): only queries sent to the router itself are handled.');
	/* DNS */
	case 'dns_stopped': return _('Easy VLESS is stopped: names are resolved by the router\'s normal DNS.');
	case 'resolve_ok_system': return _('Resolved by the router\'s DNS: %s').format(list(c.addresses)) + ms(c.ms);
	case 'resolve_ok': return _('Resolved: %s').format(list(c.addresses)) + ms(c.ms);
	case 'resolve_ok_fake': return _('Resolved to a FakeDNS placeholder: %s').format(list(c.addresses)) + ms(c.ms);
	case 'resolve_blocked_by_rule': return _('Answered empty: a DNS rule blocks this name.');
	case 'resolve_failed': return _('Not resolved: %s.').format(lookupReason(c.reason, c.rcode)) +
		(c.server_kind == 'remote' ? ' ' + _('This name is resolved by Remote DNS through the proxy: check the server (Server Test) and Remote DNS (Settings → DNS).') :
			c.server_kind == 'direct' ? ' ' + _('This name is resolved by Direct DNS: check Direct DNS (Settings → DNS) and the WAN connection.') : '');
	case 'dns_server': return (c.kind == 'blocked' ? _('A DNS rule answers empty.') : dnsServerText(c.server)) +
		(c.server && dnsRouteText(c.server) && c.kind != 'fakeip' ? ' — ' + dnsRouteText(c.server) : '');
	case 'dns_server_uncertain': return dnsServerText(c.server) + ' — ' + _('not certain: a DNS rule with geodata could apply first.');
	case 'dns_plan_unavailable': return _('The running configuration could not be read; which DNS server is used is not known.');
	case 'fake_ok': return _('In use for this name, as configured.');
	case 'fake_off': return _('Off (Settings → DNS).');
	case 'fake_not_for_domain': return _('On, but not used for this name (its rule resolves real addresses).');
	case 'fake_unexpected': return _('Conflict: the answer is a FakeDNS placeholder (%s), but the rule for this name uses a real DNS server. An old answer may be cached: restart Easy VLESS, and flush the DNS cache of the device.').format(list(c.addresses));
	case 'fake_expected_real': return _('Conflict: FakeDNS should answer this name, but a real address came back (%s). Another DNS answers before Easy VLESS, or an old answer is cached.').format(list(c.addresses));
	case 'ipv4_only': return _('IPv4 only: IPv6 (AAAA) answers are suppressed, as configured.');
	case 'ipv6_answer_unexpected': return _('Mismatch: IPv4 only is configured, but an IPv6 address was answered (%s). Another DNS answers before Easy VLESS.').format(list(c.addresses));
	case 'ipv6_answer_no_tproxy': return _('Mismatch: this proxied name gets IPv6 addresses (%s), but IPv6 TProxy is off - IPv6 connections bypass the proxy. Set Remote DNS to IPv4 only or turn IPv6 TProxy on.').format(list(c.addresses));
	case 'dual_stack': return _('IPv4 and IPv6 addresses are answered.');
	case 'no_ipv6_record': return _('The name has no IPv6 address.');
	case 'upstream_ok': return _('%s answered').format(c.server || '') + ms(c.ms) + (c.via ? ' — ' + _('through %s').format(c.via) : '');
	case 'upstream_unreachable': return _('%s did not answer: %s.').format(c.server || '', lookupReason(c.reason)) +
		(c.which == 'remote' ? ' ' + _('It is reached through the proxy (%s): run Server Test for that server, or choose another Remote DNS.').format(c.via || '?')
			: ' ' + _('Check the WAN connection or set another Direct DNS (Settings → DNS).'));
	case 'probe_skipped': return c.reason == 'not_used_for_domain' ? _('Not checked: this name is not resolved by Remote DNS.') : _('Not checked: the DNS port of sing-box was not found.');
	case 'hijack_ok': return _('Port 53 of every LAN device is redirected to Easy VLESS, also when the device uses its own DNS server.');
	case 'hijack_missing': return _('DNS redirect is on, but its firewall rule is missing: a device with its own DNS server (for example 8.8.8.8) bypasses Easy VLESS. Restart Easy VLESS.');
	case 'hijack_off_router_only': return _('DNS redirect is off: only devices that use the router as DNS are covered. A device with its own DNS server bypasses Easy VLESS (turn on DNS redirect in Settings → DNS).');
	case 'dns_not_forwarded': return _('DNS is not handed to Easy VLESS: DNS redirect is off and dnsmasq does not forward to sing-box. Turn on DNS redirect (Settings → DNS) and restart.');
	case 'client_secure_dns_unknown': return _('The router cannot see whether a device uses encrypted DNS (DoH / DoT, "Private DNS", browser "Secure DNS"). Such a device resolves names itself; domain rules then work only through sniffing. Turn it off on the device if rules do not apply.');
	case 'ecs_on': return _('Sent to Remote DNS: %s').format(c.subnet);
	/* connection panel */
	case 'unavailable': return _('Could not be checked: %s').format(c.reason);
	case 'singbox_ok': return _('sing-box %s').format(c.version || '?');
	case 'singbox_missing': return _('The sing-box binary was not found. Install a sing-box package (easy-vless-sing-box depends on it).');
	case 'backend_missing': return _('The sing-box backend of Easy VLESS is not installed (package easy-vless-sing-box).');
	case 'env_ok': return _('fw4, dnsmasq with nftset support and the kernel modules are present.');
	case 'env_error': return _('Easy VLESS cannot start: %s').format(c.detail);
	case 'running': return _('Running (PID %s)').format(c.pid) + (c.rss_kb ? ', ' + '%.1f MiB'.format(c.rss_kb / 1024) : '');
	case 'enabled_not_running': return _('The main switch is on, but sing-box is not running. See the log on Main; Save & Apply starts it again.');
	case 'switched_off': return _('The main switch is off.');
	case 'no_node': return _('No node is selected (Main → Node).');
	case 'node_missing': return _('The selected node "%s" does not exist any more. Choose a node on Main.').format(c.id);
	case 'no_proxy_target': return _('No server is used: Default and all rules go Direct or are blocked.');
	case 'node_server': return 'VLESS: ' + (c.name || c.id);
	case 'node_group': return _('URL Test group') + ': ' + (c.name || c.id) + ' (' + _('%d server(s)').format(c.members || 0) + ')';
	case 'test_group': return _('sing-box tests the servers of the group itself (Node List → URL Test live results).');
	case 'test_none': return _('Not tested yet: run Server Test in Node List.');
	case 'test_passed': return _('Passed, %d ms').format(c.delay) + ageText(c.age);
	case 'test_failed': return _('Failed: %s').format(ev.testError({ ok: false, error_kind: c.error_kind, error: c.error })) + ageText(c.age);
	case 'references_ok': return _('Every target points to an existing node.');
	case 'dangling': return _('These entries point to a node that does not exist: %s. Choose their target again on Main.').format(c.items);
	case 'rules_active': return _('%d of %d rules have a target.').format(c.active, c.total);
	case 'rules_none': return _('No rule has a target: everything goes to Default.');
	case 'rules_not_used': return _('A single node is the main node: all traffic goes to it, the rules are not used.');
	case 'running_config_ok': return _('sing-box runs with %d rule(s).').format(c.rules);
	case 'running_config_unreadable': return _('Could not be read: %s').format(c.detail);
	case 'config_differs': return _('The running sing-box has %d rule(s), the saved settings have %d: saved changes are not applied yet (Save & Apply on Main).').format(c.running, c.saved);
	case 'internet_ok_proxy': return _('The router reached the test site through Easy VLESS (HTTP %s)').format(c.http_code) + ms(c.ms);
	case 'internet_ok_direct': return _('The router reached the test site (HTTP %s)').format(c.http_code) + ms(c.ms);
	case 'internet_failed': return (c.through == 'proxy'
		? _('The router could not reach the test site through Easy VLESS (%s). Check the server (Server Test) and DNS.')
		: _('The router could not reach the test site (%s). Check the WAN connection and DNS.')).format(
			(c.http_code && c.http_code != '000') ? 'HTTP ' + c.http_code : _('curl error %s').format(c.curl_code != null ? c.curl_code : '?'));
	}
	return c.code;
}

function itemTitle(id) {
	switch (id) {
	case 'core': return _('Core', 'diagnostics');
	case 'dns': return _('DNS', 'diagnostics');
	case 'nftables': return 'nftables';
	case 'tproxy': return 'TPROXY';
	case 'vless': return 'VLESS';
	case 'routing': return _('Routing', 'diagnostics');
	case 'internet': return _('Internet', 'diagnostics');
	}
	return id;
}

function statusLabel(status, partial) {
	if (partial)
		return _('partly works');
	switch (status) {
	case 'ok': return _('works');
	case 'warn': return _('works, with a warning');
	case 'fail': return _('does not work');
	case 'off': return _('off', 'diagnostics');
	}
	return _('not checked');
}

/* The one line shown next to an item: its first failing check, else its
 * first warning, else nothing (everything fine). */
function itemSummary(item) {
	const checks = ev.arr(item.checks);
	const pick = function(st) { return checks.filter(function(c) { return c.status == st; })[0]; };
	const c = pick('fail') || pick('warn') || (item.unavailable ? checks[0] : null) || (item.status == 'off' ? pick('off') : null);
	return c ? checkTitle(c.id) + ': ' + checkText(c) : '';
}

return view.extend({
	/* pure helpers, also used by tests/diagnostics-view-test.js */
	explainRows: explainRows,
	checkText: checkText,
	checkTitle: checkTitle,
	itemSummary: itemSummary,
	statusLabel: statusLabel,
	requestError: requestError,
	targetText: targetText,
	interceptText: interceptText,

	load: function() {
		return Promise.all([ uci.load(CONFIG), ev.callStatus() ]);
	},

	mark: function(status, partial) {
		const m = MARK[partial ? 'warn' : status] || MARK.info;
		return E('span', { 'title': statusLabel(status, partial), 'style': 'display:inline-block;width:1.6em' }, m[0]);
	},

	renderChecks: function(checks) {
		return E('table', { 'class': 'table ev-diag-checks' }, ev.arr(checks).map(L.bind(function(c) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'style': 'width:2em' }, this.mark(c.status)),
				E('td', { 'class': 'td', 'style': 'width:14em' }, E('strong', {}, checkTitle(c.id))),
				E('td', { 'class': 'td' }, checkText(c))
			]);
		}, this)));
	},

	technical: function(res) {
		return E('details', { 'style': 'margin-top:.5em' }, [
			E('summary', { 'style': 'cursor:pointer;opacity:.75' }, _('Technical details')),
			E('pre', { 'style': 'white-space:pre-wrap;max-height:24em;overflow:auto;font-size:85%' }, JSON.stringify(res, null, 1))
		]);
	},

	busyNote: function(res) {
		return res.busy ? E('div', { 'class': 'alert-message warning' },
			E('p', {}, _('Easy VLESS is starting or stopping right now: the result shows a state in transition. Run the diagnostic again when it has finished.'))) : '';
	},

	loading: function(box, text) {
		dom.content(box, E('p', { 'class': 'spinning' }, text));
	},

	failed: function(box, res) {
		dom.content(box, E('div', { 'class': 'alert-message warning' }, E('p', {}, requestError(res))));
	},

	/* ---------- Connection ---------- */

	handleConnection: function() {
		const box = document.getElementById('ev-diag-connection');
		this.loading(box, _('Checking Core, DNS, nftables, TPROXY, VLESS, Routing and Internet…'));
		return ev.callDiag('connection').then(L.bind(function(res) {
			if (!res.ok)
				return this.failed(box, res);
			dom.content(box, [
				this.busyNote(res),
				E('div', { 'class': 'ev-diag-panel' }, ev.arr(res.items).map(L.bind(function(item) {
					const summary = itemSummary(item);
					return E('details', { 'class': 'ev-diag-item', 'data-item': item.id, 'data-status': item.partial ? 'partial' : item.status }, [
						E('summary', {}, [
							this.mark(item.unavailable ? 'info' : item.status, item.partial),
							E('strong', { 'style': 'display:inline-block;min-width:7em' }, itemTitle(item.id)),
							E('span', { 'class': 'ev-diag-state' }, item.unavailable ? _('not checked') : statusLabel(item.status, item.partial)),
							summary ? E('div', { 'class': 'ev-diag-summary' }, summary) : ''
						]),
						this.renderChecks(item.checks)
					]);
				}, this))),
				E('p', { 'class': 'cbi-value-description' }, _('Click an item to see its checks. DNS is checked with %s.').format(res.probe_domain || '')),
				this.technical(res)
			]);
		}, this));
	},

	/* ---------- Route Explain ---------- */

	handleExplain: function() {
		const box = document.getElementById('ev-diag-explain');
		const val = function(id) { const el = document.getElementById(id); return el ? el.value.trim() : ''; };
		const input = val('ev-explain-input');
		if (!input) {
			dom.content(box, E('div', { 'class': 'alert-message warning' }, E('p', {}, inputError('empty'))));
			return Promise.resolve();
		}
		const args = { input: input, network: val('ev-explain-network') || 'tcp' };
		if (val('ev-explain-port')) args.port = val('ev-explain-port');
		if (val('ev-explain-protocol')) args.protocol = val('ev-explain-protocol');
		if (val('ev-explain-source')) args.source = val('ev-explain-source');
		this.loading(box, _('Evaluating the routing rules…'));
		return ev.callDiag('explain', JSON.stringify(args)).then(L.bind(function(res) {
			if (!res.ok)
				return this.failed(box, res);
			const rows = explainRows(res);
			dom.content(box, [
				E('div', { 'class': 'ev-explain' }, rows.map(function(r, i) {
					return E('div', { 'class': 'ev-explain-row', 'data-row': r.id }, [
						E('div', { 'class': 'ev-explain-label' }, r.label),
						E('div', {}, [
							E('div', { 'class': 'ev-explain-value' + (r.kind ? ' ev-' + r.kind : '') }, r.text),
							ev.arr(r.sub).length ? E('ul', { 'class': 'ev-explain-sub' }, r.sub.map(function(s) { return E('li', {}, s); })) : ''
						])
					]);
				})),
				this.technical(res)
			]);
		}, this));
	},

	/* ---------- DNS ---------- */

	handleDns: function() {
		const box = document.getElementById('ev-diag-dns');
		const el = document.getElementById('ev-dns-input');
		const domain = el ? el.value.trim() : '';
		if (!domain) {
			dom.content(box, E('div', { 'class': 'alert-message warning' }, E('p', {}, inputError('not_domain'))));
			return Promise.resolve();
		}
		this.loading(box, _('Resolving %s and checking the DNS servers…').format(domain));
		return ev.callDiag('dns', domain).then(L.bind(function(res) {
			if (!res.ok)
				return this.failed(box, res);
			dom.content(box, [
				this.busyNote(res),
				E('p', {}, [ this.mark(res.status), E('strong', {}, res.domain), ' — ', statusLabel(res.status) ]),
				this.renderChecks(res.checks),
				this.technical(res)
			]);
		}, this));
	},

	/* ---------- Forwarding ---------- */

	handleForwarding: function() {
		const box = document.getElementById('ev-diag-forwarding');
		this.loading(box, _('Reading nftables and the routing tables…'));
		return ev.callDiag('forwarding').then(L.bind(function(res) {
			if (!res.ok)
				return this.failed(box, res);
			const g = res.groups || {};
			const group = L.bind(function(title, grp) {
				if (!grp)
					return '';
				return E('div', {}, [
					E('p', { 'style': 'margin:.6em 0 .2em' }, [ this.mark(grp.status, grp.partial), E('strong', {}, title), ' — ', statusLabel(grp.status, grp.partial) ]),
					this.renderChecks(grp.checks)
				]);
			}, this);
			dom.content(box, [
				this.busyNote(res),
				group('nftables', g.nftables),
				group('TPROXY / REDIRECT', g.tproxy),
				this.technical(res)
			]);
		}, this));
	},

	style: function() {
		return E('style', {}, [
			'.ev-diag-item { border: 1px solid rgba(128,128,128,.35); border-radius: .4em; margin: .3em 0; padding: .4em .7em; }',
			'.ev-diag-item > summary { cursor: pointer; }',
			'.ev-diag-state { opacity: .75; }',
			'.ev-diag-summary { margin: .2em 0 0 1.6em; font-size: 92%; }',
			'.ev-diag-checks td { vertical-align: top; }',
			'.ev-explain { border: 1px solid rgba(128,128,128,.35); border-radius: .4em; padding: .3em .8em; }',
			'.ev-explain-row { display: grid; grid-template-columns: 9em 1fr; gap: .2em .8em; padding: .45em 0; border-bottom: 1px solid rgba(128,128,128,.2); }',
			'.ev-explain-row:last-child { border-bottom: 0; }',
			'.ev-explain-label { opacity: .75; }',
			'.ev-explain-value { font-weight: bold; overflow-wrap: anywhere; }',
			'.ev-explain-value.ev-warn { color: #b26a00; }',
			'.ev-explain-value.ev-bad { color: #c62828; }',
			'.ev-explain-sub { margin: .2em 0 0 1.1em; font-size: 92%; }',
			'.ev-diag-form { display: flex; flex-wrap: wrap; gap: .4em; align-items: center; margin: .5em 0; }',
			'.ev-diag-form input, .ev-diag-form select { width: auto; min-width: 0; max-width: 100%; }',
			'@media (max-width: 600px) { .ev-explain-row { grid-template-columns: 1fr; } }'
		].join('\n'));
	},

	render: function(data) {
		const status = data[1] || {};
		ev.lastStatus = status;
		const enter = function(fn) {
			return function(e) { if (e.keyCode == 13) { e.preventDefault(); return fn(); } };
		};
		const explain = ui.createHandlerFn(this, 'handleExplain');
		const dns = ui.createHandlerFn(this, 'handleDns');

		poll.add(L.bind(ev.refreshStatus, ev), 5);
		return E('div', { 'class': 'ev-page' }, [
			ev.pageStyle(),
			this.style(),
			E('h2', {}, _('Diagnostics')),
			E('div', { 'class': 'cbi-map-descr' }, _('Why does traffic go the way it goes, and what is broken if it does not. Everything here only reads the state of the router: nothing is started, stopped or changed.')),
			ev.renderHeader(null, status, null, true, false),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Connection')),
				E('div', { 'class': 'cbi-section-descr' }, _('One check of every part Easy VLESS needs. Each item shows what works, what does not and why.')),
				E('div', { 'class': 'ev-diag-form' }, E('button', { 'class': 'btn cbi-button cbi-button-action', 'id': 'ev-diag-connection-btn',
					'click': ui.createHandlerFn(this, 'handleConnection') }, _('Run diagnostics'))),
				E('div', { 'id': 'ev-diag-connection' })
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Route Explain')),
				E('div', { 'class': 'cbi-section-descr' }, _('Enter a domain, an IP address, host:port or a URL: Easy VLESS shows which rule applies, why, where the traffic goes and how its DNS is resolved.')),
				E('div', { 'class': 'ev-diag-form' }, [
					E('input', { 'type': 'text', 'class': 'cbi-input-text', 'id': 'ev-explain-input', 'placeholder': 'youtube.com', 'style': 'width:18em',
						'keydown': enter(explain) }),
					E('select', { 'class': 'cbi-input-select', 'id': 'ev-explain-network', 'title': _('Network of the connection') }, [
						E('option', { 'value': 'tcp' }, 'TCP'), E('option', { 'value': 'udp' }, 'UDP') ]),
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'id': 'ev-explain-btn', 'click': explain }, _('Explain'))
				]),
				E('details', {}, [
					E('summary', { 'style': 'cursor:pointer;opacity:.75' }, _('More: port, protocol, source')),
					E('div', { 'class': 'ev-diag-form' }, [
						E('label', {}, [ _('Port', 'diagnostics') + ' ', E('input', { 'type': 'text', 'class': 'cbi-input-text', 'id': 'ev-explain-port', 'placeholder': '443', 'style': 'width:6em' }) ]),
						E('label', {}, [ _('Sniffed protocol') + ' ', E('select', { 'class': 'cbi-input-select', 'id': 'ev-explain-protocol' }, [
							E('option', { 'value': '' }, _('by port (443 TLS / QUIC, 80 HTTP)')),
							E('option', { 'value': 'tls' }, 'TLS'), E('option', { 'value': 'http' }, 'HTTP'),
							E('option', { 'value': 'quic' }, 'QUIC'), E('option', { 'value': 'bittorrent' }, 'BitTorrent'),
							E('option', { 'value': 'none' }, _('not recognised')) ]) ]),
						E('label', {}, [ _('Source IP') + ' ', E('input', { 'type': 'text', 'class': 'cbi-input-text', 'id': 'ev-explain-source', 'placeholder': '192.168.1.100', 'style': 'width:11em' }) ])
					])
				]),
				E('div', { 'id': 'ev-diag-explain', 'style': 'margin-top:.6em' })
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('DNS diagnostics')),
				E('div', { 'class': 'cbi-section-descr' }, _('Resolves one domain the way a LAN device does and shows which DNS answers it, through which route, and what is wrong if it fails.')),
				E('div', { 'class': 'ev-diag-form' }, [
					E('input', { 'type': 'text', 'class': 'cbi-input-text', 'id': 'ev-dns-input', 'placeholder': 'youtube.com', 'style': 'width:18em', 'keydown': enter(dns) }),
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'id': 'ev-dns-btn', 'click': dns }, _('Check DNS'))
				]),
				E('div', { 'id': 'ev-diag-dns' })
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Forwarding diagnostics')),
				E('div', { 'class': 'cbi-section-descr' }, _('The firewall side: the nft table, chains and sets of Easy VLESS, policy routing, TPROXY / REDIRECT for TCP and UDP, LAN and router interception, IPv6, port exceptions.')),
				E('div', { 'class': 'ev-diag-form' }, E('button', { 'class': 'btn cbi-button cbi-button-action', 'id': 'ev-forwarding-btn',
					'click': ui.createHandlerFn(this, 'handleForwarding') }, _('Check forwarding'))),
				E('div', { 'id': 'ev-diag-forwarding' })
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
