/*
 * Easy VLESS - Diagnostics view (0.9.0), test of the text the page shows
 * (luci/htdocs/.../view/easy_vless/diagnostics.js) without a browser: the
 * view is evaluated the way LuCI's loader does, with stand-ins for LuCI.
 *
 *   node tests/diagnostics-view-test.js      (static checks, CI "checks" job)
 *
 * Covered: the Route Explain rows for results of explain.lua (rule, reason,
 * target, DNS, DNS route, forwarding, uncertain and skipped rules, errors),
 * and that every result code the router can send (diagnose.lua, explain.lua)
 * has a text - no raw code and no bare "failed" reaches the user.
 */
'use strict';
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
function check(msg, cond) {
	if (cond) { pass++; console.log('PASS: ' + msg); }
	else { fail++; console.log('FAIL: ' + msg); }
}

global.L = {
	bind: function(fn, self) { const a = Array.prototype.slice.call(arguments, 2); return function() { return fn.apply(self, a.concat(Array.prototype.slice.call(arguments))); }; },
	toArray: function(x) { return x == null ? [] : (Array.isArray(x) ? x : [ x ]); }
};
global._ = function(s) { return s; };
global.E = function(tag, attrs, children) { return { tag: tag, attrs: attrs, children: children }; };
global.window = { setTimeout: function() { return 1; } };
String.prototype.format = function() {
	const args = arguments;
	let i = 0;
	return this.replace(/%(\.\d+)?[sdf]/g, function() { return String(args[i++]); });
};
const root = path.join(__dirname, '..');
const res = path.join(root, 'luci', 'htdocs', 'luci-static', 'resources');
const baseclass = { extend: function(o) { return o; } };
const rpc = { declare: function() { return function() { return Promise.resolve({}); }; } };
const uci = { get: function() { return null; }, sections: function() { return []; } };
const ev = new Function('baseclass', 'rpc', 'uci', 'ui', 'dom', fs.readFileSync(path.join(res, 'easy_vless', 'common.js'), 'utf8'))(baseclass, rpc, uci, {}, {});
const view = new Function('view', 'uci', 'ui', 'dom', 'poll', 'ev', fs.readFileSync(path.join(res, 'view', 'easy_vless', 'diagnostics.js'), 'utf8'))(
	{ extend: function(o) { return o; } }, uci, {}, {}, {}, ev);

/* ---- Route Explain: youtube.com -> PROXY -> server, Remote DNS through the proxy, TPROXY ---- */
const server = { kind: 'server', id: 'srv', name: 'Finland #1', tag: 'PROXY' };
const youtube = {
	ok: true,
	input: { text: 'youtube.com', kind: 'domain', host: 'youtube.com', port: 443, port_assumed: true, network: 'tcp', protocol: 'tls', protocol_assumed: true },
	config: { source: 'running', node: 'main_router' },
	route: {
		certain: true, possible: [],
		match: { kind: 'rule', index: 5, rule_id: 'PROXY', rule_name: 'PROXY', priority: 2, action: 'route',
			reasons: [ { code: 'domain_keyword', item: 'youtube.com', origin: { kind: 'resource', id: 'proxy', name: 'PROXY' } } ], target: server },
		skipped: [ { rule_id: 'RUSSIA', rule_name: 'RUSSIA', priority: 1, why: { code: 'domain_no_match' } } ]
	},
	dns: {
		a: { certain: true, match: { kind: 'rule', action: 'route', server: { kind: 'remote', tag: 'PROXY', type: 'udp', address: '1.1.1.1', port: 53, detour: server } } },
		aaaa: { certain: true, match: { kind: 'rule', action: 'predefined' } }
	},
	intercept: { intercepted: 'yes', method: 'tproxy', reasons: [], lan: true, router: true }
};
const row = function(rows, id) { return rows.filter(function(r) { return r.id == id; })[0] || {}; };
let rows = view.explainRows(youtube);
check('explain: rows in reading order (' + rows.map(function(r) { return r.id; }).join(',') + ')',
	rows.map(function(r) { return r.id; }).join(',') == 'input,rule,reason,target,dns,dns_route,forwarding,skipped,config');
check('explain: what was checked, with the assumptions marked', row(rows, 'input').text == 'youtube.com' && /TCP/.test(row(rows, 'input').sub[0]) && /443 \(assumed\)/.test(row(rows, 'input').sub[0]) && /TLS \(assumed/.test(row(rows, 'input').sub[0]));
check('explain: rule and priority', row(rows, 'rule').text == 'PROXY (priority 2)');
check('explain: reason names the matching entry and the resource it comes from', /contains "youtube.com"/.test(row(rows, 'reason').text) && /from the resource PROXY/.test(row(rows, 'reason').text));
check('explain: target is the server by name', row(rows, 'target').text == 'VLESS: Finland #1');
check('explain: DNS = Remote DNS with its address, IPv6 suppressed', /^Remote DNS \(udp:\/\/1\.1\.1\.1:53\)/.test(row(rows, 'dns').text) && row(rows, 'dns').sub.some(function(s) { return /IPv4 only/.test(s); }));
check('explain: DNS route through the proxy server', row(rows, 'dns_route').text == 'through the proxy: VLESS: Finland #1');
check('explain: forwarding TPROXY', row(rows, 'forwarding').text == 'TPROXY');
check('explain: the rule checked before and why it does not apply', /RUSSIA — the domain is not in its lists/.test(row(rows, 'skipped').sub[0]));
check('explain: says which configuration it is based on', /running with right now/.test(row(rows, 'config').text));

const clone = function(o) { return JSON.parse(JSON.stringify(o)); };
let r = clone(youtube);
r.route.match = { kind: 'default', action: 'route', reasons: [], target: { kind: 'direct' } };
r.config.source = 'saved';
rows = view.explainRows(r);
check('explain: no rule -> Default, with the reason', row(rows, 'rule').text == 'no rule matches: Default' && /Default target/.test(row(rows, 'reason').text) && row(rows, 'target').text == 'Direct');
check('explain: stopped service is stated', /saved settings/.test(row(rows, 'config').text));

r = clone(youtube);
r.dns.a.match.server = { kind: 'fakeip', tag: 'remote_fakeip', range4: '198.18.0.0/16' };
r.intercept.reasons = [ { code: 'fake_ip' } ];
rows = view.explainRows(r);
check('explain: FakeDNS is explained, no DNS route row for a placeholder', /^FakeDNS/.test(row(rows, 'dns').text) && row(rows, 'dns').sub.some(function(s) { return /placeholder address/.test(s); }) && !row(rows, 'dns_route').id);
check('explain: FakeDNS address is redirected on every port', /TPROXY — .*every port/.test(row(rows, 'forwarding').text));

r = clone(youtube);
r.route.certain = false;
r.route.possible = [ { kind: 'rule', index: 4, rule_id: 'GEO', rule_name: 'GEO', priority: 1, action: 'route', target: { kind: 'direct' }, reasons: [ { code: 'rule_set', item: 'geoip-ru' } ] } ];
rows = view.explainRows(r);
check('explain: an undecidable rule is shown as "not certain" with its reason, not hidden', row(rows, 'uncertain').kind == 'warn' && /GEO → Direct: it uses geodata \(geoip-ru\)/.test(row(rows, 'uncertain').sub[0]));

r = clone(youtube);
r.intercept = { intercepted: 'no', method: 'tproxy', reasons: [ { code: 'port_not_redirected', port: 8443, ports: '80,443' } ], lan: true, router: true };
rows = view.explainRows(r);
check('explain: not intercepted is a warning with the cause and the place to change it', row(rows, 'forwarding').kind == 'warn' && /port 8443 is outside the redirected ports \(80,443/.test(row(rows, 'forwarding').text));

r = clone(youtube);
r.route.match.target = { kind: 'group', id: 'g1', name: 'Fastest', tag: 'urltest-g1', members: [ { id: 'a', name: 'Finland' }, { id: 'b', name: 'Germany' } ], now: { id: 'b', name: 'Germany', delay: 85 } };
check('explain: URL Test group with the server in use', view.targetText(r.route.match.target) == 'URL Test group: Fastest → now using Germany (85 ms)');
delete r.route.match.target.now;
check('explain: URL Test group without live data lists its servers', view.targetText(r.route.match.target) == 'URL Test group: Fastest (Finland, Germany)');
check('explain: an outbound missing in the configuration is "unknown", not invented', /unknown outbound "x"/.test(view.targetText({ kind: 'unknown', tag: 'x' })));

r = clone(youtube);
r.input = { text: '8.8.8.8', kind: 'ip', ip: '8.8.8.8', port: 53, network: 'udp' };
delete r.dns;
r.route.match = { kind: 'rule', rule_id: 'UDP', rule_name: 'UDP', priority: 4, action: 'route', target: server, reasons: [ { code: 'network', item: 'udp', value: 'udp' } ] };
r.route.skipped = [ { rule_id: 'PROXY', rule_name: 'PROXY', priority: 2, why: { code: 'no_domain' } }, { rule_id: 'QUIC', rule_name: 'QUIC', priority: 3, why: { code: 'port', item: '443', value: 53 } } ];
rows = view.explainRows(r);
check('explain: IP input - no DNS rows, IP shown', !row(rows, 'dns').id && row(rows, 'input').text == '8.8.8.8' && /IP address · UDP · port 53/.test(row(rows, 'input').sub[0]));
check('explain: skip reasons for an IP', /no domain name is known/.test(row(rows, 'skipped').sub[0]) && /it is for port 443, the connection uses port 53/.test(row(rows, 'skipped').sub[1]));

/* ---- request errors: concrete, never a bare "failed" ---- */
check('error: busy', /busy with another operation/.test(view.requestError({ ok: false, error: 'busy' })));
check('error: invalid input', /not a valid domain or IP/.test(view.requestError({ ok: false, error: 'input', reason: 'invalid' })) && /between 1 and 65535/.test(view.requestError({ ok: false, error: 'input', reason: 'port' })));
check('error: configuration cannot be generated, with the reason of the router', /No node selected/.test(view.requestError({ ok: false, error: 'config', detail: 'No node selected' })));
check('error: interrupted by a start / stop', /Run it again/.test(view.requestError({ ok: false, error: 'interrupted' })));
check('error: rpc failure', /did not answer: timeout/.test(view.requestError({ rpc_error: true, error: 'timeout' })));

/* ---- every code of the router has a text ---- */
const lua = function(f) { return fs.readFileSync(path.join(root, 'root', 'usr', 'lib', 'lua', 'luci', 'easy_vless', f), 'utf8'); };
const diag = lua('diagnose.lua');
const codes = {};
let m;
/* add(list, "<check id>", <status>, <code>, ...): the quoted words of such a
 * line (before its parameter table) without the check id and the status
 * words are the codes */
const NOT_CODE = { ok: 1, warn: 1, fail: 1, off: 1, info: 1, group: 1 };
diag.split('\n').forEach(function(line) {
	const p = line.indexOf('add(');
	if (p < 0 || /^\s*(local )?function/.test(line))
		return;
	const words = (line.slice(p).split('{')[0].match(/"([a-z][a-z0-9_]+)"/g) || []).map(function(w) { return w.replace(/"/g, ''); });
	words.slice(1).forEach(function(w) { if (!NOT_CODE[w]) codes[w] = true; });
});
codes.unavailable = true;
const all = Object.keys(codes);
check('diagnose.lua: check codes found (' + all.length + ')', all.length > 80);
const sample = { addresses: [ '1.2.3.4' ], server: { kind: 'remote', address: '1.1.1.1', type: 'udp', port: 53, detour: server }, items: 'x', reason: 'timeout', detail: 'd', delay: 5, age: 70, error_kind: 'timeout' };
const missing = all.filter(function(c) { return view.checkText(Object.assign({ code: c }, sample)) === c; });
check('every diagnose.lua check code has a text' + (missing.length ? ' - missing: ' + missing.join(', ') : ''), missing.length == 0);
const vague = all.filter(function(c) { return /^(failed|error|not working)\.?$/i.test(view.checkText(Object.assign({ code: c }, sample))); });
check('no check text is a bare "failed" / "error"', vague.length == 0);
const ids = {};
const reId = /add\(\s*\w+\s*,\s*"([a-z0-9_]+)"/g;
while ((m = reId.exec(diag))) ids[m[1]] = true;
const noTitle = Object.keys(ids).filter(function(id) { return view.checkTitle(id) === id && id != 'nftables'; });
check('every check has a title' + (noTitle.length ? ' - missing: ' + noTitle.join(', ') : ''), noTitle.length == 0);

/* 1.0: an unknown DNS server is said as such, with what to do - never a bare "unknown" */
check('"DNS used" unknown: the missing server is named, with what to do',
	/not part of the running configuration \(gone\)/.test(view.checkText({ code: 'dns_server_unknown', tag: 'gone' })) && /Restart/.test(view.checkText({ code: 'dns_server_unknown', tag: 'gone' })));
check('"DNS used" ok: the server and its route are shown',
	/^Remote DNS \(udp:\/\/1\.1\.1\.1:53\) — through the proxy: VLESS: Finland #1$/.test(view.checkText({ code: 'dns_server', kind: 'remote', server: sample.server })));

/* failing checks say what to do */
[ 'table_missing', 'policy_rule_missing', 'redirect_rule_missing', 'lan_jump_missing', 'upstream_unreachable', 'dns_not_forwarded', 'enabled_not_running', 'dangling', 'internet_failed' ].forEach(function(c) {
	const t = view.checkText(Object.assign({ code: c, which: 'remote', via: 'Finland', through: 'proxy' }, sample));
	check('"' + c + '" explains what to do', /Restart|Check|check|run Server Test|Turn on|Save & Apply|Choose|See the log/.test(t));
});

/* summary line of a panel item */
const item = { id: 'tproxy', status: 'fail', partial: true, checks: [
	{ id: 'policy', status: 'ok', code: 'policy_ok', mark: '0x45560000', table: '998' },
	{ id: 'tcp', status: 'ok', code: 'redirect_ok', method: 'TPROXY', port: '1041', proto: 'TCP' },
	{ id: 'udp', status: 'fail', code: 'redirect_rule_missing', method: 'TPROXY', chain: 'EV_MANGLE', proto: 'UDP' } ] };
check('panel: the summary of an item is its failing check, with the reason', /^UDP forwarding: No TPROXY rule for UDP in the chain EV_MANGLE/.test(view.itemSummary(item)));
check('panel: "partly works"', view.statusLabel('fail', true) == 'partly works' && view.statusLabel('fail') == 'does not work' && view.statusLabel('ok') == 'works');
check('panel: nothing to say when everything is fine', view.itemSummary({ id: 'core', status: 'ok', checks: [ { id: 'binary', status: 'ok', code: 'singbox_ok', version: '1.12' } ] }) == '');
check('panel: an unavailable item says why', /Could not be checked: nft: Operation not permitted/.test(view.itemSummary({ id: 'nftables', status: 'info', unavailable: true, checks: [ { id: 'nftables', status: 'info', code: 'unavailable', reason: 'nft: Operation not permitted' } ] })));

/* explain.lua reason codes */
const expl = lua('explain.lua');
const rcodes = {};
const reC = /code = "([a-z0-9_]+)"/g;
while ((m = reC.exec(expl))) rcodes[m[1]] = true;
const src = fs.readFileSync(path.join(res, 'view', 'easy_vless', 'diagnostics.js'), 'utf8');
const unhandled = Object.keys(rcodes).filter(function(c) { return c != 'no_match' && src.indexOf("'" + c + "'") < 0; });
check('every explain.lua reason code (' + Object.keys(rcodes).length + ') is handled by the view' + (unhandled.length ? ' - missing: ' + unhandled.join(', ') : ''), unhandled.length == 0);

console.log('\n===== Diagnostics view: ' + pass + ' passed, ' + fail + ' failed =====');
process.exit(fail ? 1 : 0);
