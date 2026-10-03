'use strict';
'require baseclass';

/*
 * Easy VLESS - checks of the routing rules for Rule Manage (0.9.0).
 *
 * Pure functions over plain data (no uci, no DOM; tests/rule-check-test.js).
 * They follow the routing that really runs (util_sing-box.lua -> sing-box
 * route rules, the same semantics Route Explain evaluates):
 *   - rules are checked from top to bottom, the first matching rule with a
 *     target wins; a rule without a target is not generated at all;
 *   - a rule matches when every condition group it has matches: network,
 *     port, source, source port, protocol, inbound, and the destination
 *     group, in which Domain Resource, Domain and IP entries are
 *     alternatives (any one of them);
 *   - no condition in a group = that group matches everything.
 *
 * A finding is only reported when it can be proven from the settings. Two
 * rules that merely overlap (PROXY domains above a general UDP rule) are
 * normal and are not reported; what is inside a prepared resource or a
 * geodata list is not known here, so such entries are compared by name only.
 *
 * analyze(input) -> [{ rule, level: 'error' | 'warn' | 'info', code, ... }]
 *   input = {
 *     rules: [{ id, name, target, cond: { domain_resource: [ids],
 *               domain_list, ip_list, network, port, source, sourcePort,
 *               protocol, inbound } }]     in priority order
 *     defaultTarget,
 *     targetKind: function(id) -> 'direct' | 'block' | 'default' | 'server'
 *                 | 'group' | 'empty_group' | null (does not exist)
 *     resourceOk: function(id) -> true if the resource is installed
 *   }
 */

function lines(v) {
	return String(v || '').split(/\r?\n/).map(function(l) { return l.trim(); }).filter(function(l) { return l && l.charAt(0) != '#'; });
}

function words(v) {
	return (Array.isArray(v) ? v.join(' ') : String(v || '')).split(/[\s,]+/).filter(function(x) { return x; });
}

/* "80,443,1000:2000" -> [[80, 80], [443, 443], [1000, 2000]] */
function ranges(v) {
	return words(v).map(function(p) {
		const m = p.match(/^(\d+)(?:[:-](\d+))?$/);
		if (!m)
			return null;
		return [ +m[1], m[2] ? +m[2] : +m[1] ];
	}).filter(function(r) { return r; });
}

function rangesCover(a, b) {
	return b.every(function(rb) {
		return a.some(function(ra) { return ra[0] <= rb[0] && rb[1] <= ra[1]; });
	});
}

function ip4(s) {
	const m = String(s).match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)(?:\/(\d+))?$/);
	if (!m || m.slice(1, 5).some(function(x) { return +x > 255; }) || (m[5] != null && +m[5] > 32))
		return null;
	return { addr: ((+m[1] * 256 + +m[2]) * 256 + +m[3]) * 256 + +m[4], bits: m[5] != null ? +m[5] : 32 };
}

/* does the address entry a (IP, CIDR, geoip:x) contain entry b? */
function ipCovers(a, b) {
	if (a == b)
		return true;
	const x = ip4(a), y = ip4(b);
	if (!x || !y || x.bits > y.bits)
		return false;
	const size = Math.pow(2, 32 - x.bits);
	return Math.floor(x.addr / size) == Math.floor(y.addr / size);
}

/* a domain list line as { type: full | domain | regexp | keyword | other, value } */
function domainEntry(line) {
	const m = line.match(/^([a-z-]+):(.*)$/);
	if (!m)
		return { type: 'keyword', value: line.toLowerCase() };
	if (m[1] == 'full' || m[1] == 'domain')
		return { type: m[1], value: m[2].toLowerCase() };
	if (m[1] == 'regexp')
		return { type: 'regexp', value: m[2] };
	return { type: 'other', value: line };
}

/* does every host matched by entry b also match entry a? */
function domainCovers(a, b) {
	if (a.type == b.type && a.value == b.value)
		return true;
	if (b.type != 'full' && b.type != 'domain')
		return false;
	if (a.type == 'domain')
		return b.value == a.value || b.value.slice(-a.value.length - 1) == '.' + a.value;
	if (a.type == 'keyword')
		return b.value.indexOf(a.value) > -1;
	return false;
}

function norm(cond) {
	cond = cond || {};
	const n = {
		resources: words(cond.domain_resource),
		domains: lines(cond.domain_list).map(domainEntry),
		ips: lines(cond.ip_list),
		network: (cond.network == 'tcp' || cond.network == 'udp') ? cond.network : null,
		port: ranges(cond.port),
		source: words(cond.source),
		sourcePort: ranges(cond.sourcePort),
		protocol: words(cond.protocol),
		inbound: words(cond.inbound)
	};
	n.hasDest = !!(n.resources.length || n.domains.length || n.ips.length);
	n.empty = !n.hasDest && !n.network && !n.port.length && !n.source.length && !n.sourcePort.length && !n.protocol.length && !n.inbound.length;
	return n;
}

function setCovers(a, b) {
	return b.every(function(x) { return a.indexOf(x) > -1; });
}

/* Does rule a match every connection rule b matches (provably)? */
function covers(a, b) {
	if (a.network && a.network != b.network)
		return false;
	if (a.port.length && !(b.port.length && rangesCover(a.port, b.port)))
		return false;
	if (a.sourcePort.length && !(b.sourcePort.length && rangesCover(a.sourcePort, b.sourcePort)))
		return false;
	if (a.source.length && !(b.source.length && b.source.every(function(y) { return a.source.some(function(x) { return ipCovers(x, y); }); })))
		return false;
	if (a.protocol.length && !(b.protocol.length && setCovers(a.protocol, b.protocol)))
		return false;
	if (a.inbound.length && !(b.inbound.length && setCovers(a.inbound, b.inbound)))
		return false;
	if (a.hasDest) {
		if (!b.hasDest)
			return false;
		if (!setCovers(a.resources, b.resources))
			return false;
		if (!b.domains.every(function(y) { return a.domains.some(function(x) { return domainCovers(x, y); }); }))
			return false;
		if (!b.ips.every(function(y) { return a.ips.some(function(x) { return ipCovers(x, y); }); }))
			return false;
	}
	return true;
}

/* Conditions that contradict each other: the rule can never match.
 * sing-box sniffs TLS and HTTP on TCP and QUIC on UDP. */
function contradiction(cond) {
	const n = norm(cond);
	if (!n.network || !n.protocol.length)
		return null;
	const possible = n.protocol.filter(function(p) {
		if (p == 'quic')
			return n.network == 'udp';
		if (p == 'tls' || p == 'http')
			return n.network == 'tcp';
		return true;
	});
	if (possible.length)
		return null;
	return { code: 'protocol_network', protocol: n.protocol.join(', ').toUpperCase(), network: n.network.toUpperCase() };
}

/* Domain / IP entries of b that an earlier rule a already catches (same
 * line in both, and a's other conditions cover b's). */
function sharedEntries(a, b) {
	const rest = function(n) { return Object.assign({}, n, { resources: [], domains: [], ips: [], hasDest: false }); };
	if (!a.hasDest || !b.hasDest || !covers(rest(a), rest(b)))
		return [];
	const out = [];
	b.resources.forEach(function(r) { if (a.resources.indexOf(r) > -1) out.push({ kind: 'resource', value: r }); });
	b.domains.forEach(function(y) {
		if (a.domains.some(function(x) { return domainCovers(x, y); }))
			out.push({ kind: 'domain', value: y.value });
	});
	b.ips.forEach(function(y) {
		if (a.ips.some(function(x) { return ipCovers(x, y); }))
			out.push({ kind: 'ip', value: y });
	});
	return out;
}

return baseclass.extend({
	covers: function(a, b) { return covers(norm(a), norm(b)); },
	contradiction: contradiction,
	ipCovers: ipCovers,

	analyze: function(input) {
		const out = [];
		const rules = (input.rules || []).map(function(r) {
			return { id: r.id, name: r.name || r.id, target: r.target || '', n: norm(r.cond), cond: r.cond };
		});
		const kindOf = input.targetKind || function() { return 'server'; };
		const effective = function(t) { return t == '_default' ? (input.defaultTarget || '_direct') : t; };

		const defKind = kindOf(input.defaultTarget || '_direct');
		if (defKind == null)
			out.push({ rule: null, level: 'error', code: 'default_missing', target: input.defaultTarget });
		else if (defKind == 'empty_group')
			out.push({ rule: null, level: 'error', code: 'default_empty_group', target: input.defaultTarget });

		const active = [];
		rules.forEach(function(r, i) {
			const add = function(level, code, extra) {
				out.push(Object.assign({ rule: r.id, name: r.name, level: level, code: code, order: i + 1 }, extra || {}));
			};

			r.n.resources.forEach(function(id) {
				if (input.resourceOk && !input.resourceOk(id))
					add('error', 'resource_missing', { resource: id });
			});
			const bad = contradiction(r.cond);
			if (bad)
				add('warn', bad.code, bad);

			if (!r.target) {
				add('info', 'no_target');
				return;
			}
			const kind = kindOf(r.target);
			if (kind == null)
				add('error', 'target_missing', { target: r.target });
			else if (kind == 'empty_group')
				add('error', 'target_empty_group', { target: r.target });
			else if (r.target == '_default' && defKind == null)
				add('error', 'target_default_missing');

			/* an earlier active rule that matches everything this one matches */
			const above = active.filter(function(a) { return covers(a.n, r.n); })[0];
			if (above) {
				const same = effective(above.target) == effective(r.target);
				if (above.n.empty)
					add(same ? 'info' : 'warn', 'after_match_all', { other: above.id, otherName: above.name, sameTarget: same });
				else if (covers(r.n, above.n))
					add(same ? 'info' : 'warn', same ? 'duplicate' : 'conflict', { other: above.id, otherName: above.name });
				else
					add(same ? 'info' : 'warn', same ? 'redundant' : 'shadowed', { other: above.id, otherName: above.name });
			}
			else {
				/* part of its entries is caught by an earlier rule with another target */
				active.some(function(a) {
					if (effective(a.target) == effective(r.target))
						return false;
					const shared = sharedEntries(a.n, r.n);
					if (!shared.length)
						return false;
					add('warn', 'overlap', { other: a.id, otherName: a.name, entries: shared.slice(0, 3).map(function(e) { return e.value; }), more: Math.max(0, shared.length - 3) });
					return true;
				});
			}

			if (r.n.empty && !bad)
				add('info', 'match_all', { last: i == rules.length - 1 });
			active.push(r);
		});
		return out;
	}
});
