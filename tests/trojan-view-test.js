/*
 * Easy VLESS 1.1 - Trojan in LuCI, regression test without a browser (same
 * loader stand-ins as use-server-test.js / html-safety-test.js).
 *
 *   node tests/trojan-view-test.js      (static checks, CI "checks" job)
 *
 * Covered: a Trojan node is a server everywhere a VLESS node is (Node List,
 * targets, references), "Use" with a Trojan server changes what "Use" with
 * a VLESS server changes and nothing else, the trojan:// URL of a server
 * (Copy) and that it carries a hostile name or password only as data, the
 * link check of the First Run Wizard, the Node List editor.
 */
'use strict';
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
function check(msg, cond) {
	if (cond) { pass++; console.log('PASS: ' + msg); }
	else { fail++; console.log('FAIL: ' + msg); }
}

let UCI = [];
const sec = function(sid) { return UCI.filter(function(s) { return s['.name'] == sid; })[0] || null; };
const uci = {
	get: function(conf, sid, opt) {
		const s = sec(sid);
		if (!s) return null;
		return opt == null ? s : (s[opt] == null ? null : s[opt]);
	},
	set: function(conf, sid, opt, val) { const s = sec(sid); if (s) s[opt] = val; },
	unset: function(conf, sid, opt) { const s = sec(sid); if (s) delete s[opt]; },
	add: function(conf, type, name) { UCI.push({ '.name': name, '.type': type }); return name; },
	sections: function(conf, type) { return UCI.filter(function(s) { return s['.type'] == type; }); }
};
/* a minimal DOM: what LuCI's dom.append does with its "data" argument */
function luciE(tag, attrs, data) {
	if (!(attrs instanceof Object) || Array.isArray(attrs)) { data = attrs; attrs = null; }
	const el = { tag: tag, attrs: attrs || {}, html: null, children: [], select: function() {}, appendChild: function() {}, querySelector: function() { return null; } };
	if (Array.isArray(data))
		data.forEach(function(c) { el.children.push((c && typeof(c) == 'object') ? c : { text: '' + c }); });
	else if (data && typeof(data) == 'object')
		el.children.push(data);
	else if (data !== null && data !== undefined)
		el.html = '' + data;      /* innerHTML */
	return el;
}
function usesInnerHTML(el) {
	if (!el || typeof(el) != 'object')
		return false;
	if (el.html != null)
		return true;
	return (el.children || []).some(usesInnerHTML);
}

global.L = {
	require: function() { return Promise.reject(new Error('no uqr')); },
	bind: function(fn, self) { const a = Array.prototype.slice.call(arguments, 2); return function() { return fn.apply(self, a.concat(Array.prototype.slice.call(arguments))); }; },
	toArray: function(x) { return x == null ? [] : (Array.isArray(x) ? x : [ x ]); },
	url: function(p) { return '/cgi-bin/luci/' + p; }
};
global._ = function(s) { return s; };
global.E = luciE;
global.window = { setTimeout: function() { return 1; } };
String.prototype.format = function() {
	const args = arguments;
	let i = 0;
	return this.replace(/%(\.\d+)?[sdfh]/g, function(m) {
		const v = String(args[i++]);
		return m == '%h' ? v.replace(/&/g, '&#38;').replace(/</g, '&#60;').replace(/>/g, '&#62;').replace(/"/g, '&#34;').replace(/'/g, '&#39;') : v;
	});
};
const modals = [];
const ui = { showModal: function(title, body) { modals.push({ title: title, body: body }); }, hideModal: function() {} };
const res = path.join(__dirname, '..', 'luci', 'htdocs', 'luci-static', 'resources');
const ev = new Function('baseclass', 'rpc', 'uci', 'ui', 'dom', fs.readFileSync(path.join(res, 'easy_vless', 'common.js'), 'utf8'))(
	{ extend: function(o) { return o; } }, { declare: function() { return function() { return Promise.resolve({}); }; } }, uci, ui, {});

const R = 'main_router';
const TEMPLATES = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'root', 'usr', 'share', 'easy_vless', 'resources', 'manifest.json'), 'utf8')).rule_templates;
const UUID = '00000000-0000-4000-8000-000000000001';
function setup(node, targets, def) {
	UCI = [
		{ '.name': 'global', '.type': 'global', node: node },
		{ '.name': 'A', '.type': 'nodes', protocol: 'vless', type: 'sing-box', remarks: 'Finland', add_mode: '0', address: 'fi.example.net', port: '443', uuid: UUID,
			transport: 'tcp', tls: '1', tls_serverName: 'fi.example.net', flow: 'xtls-rprx-vision', encryption: 'none' },
		{ '.name': 'T', '.type': 'nodes', protocol: 'trojan', type: 'sing-box', remarks: 'Trojan NL', add_mode: '0', address: 'nl.example.net', port: '443', password: 'p@ss word/1',
			transport: 'tcp', tls: '1', tls_serverName: 'sni.example.net' },
		{ '.name': 'TS', '.type': 'nodes', protocol: 'trojan', type: 'sing-box', remarks: 'Trojan sub', add_mode: '2', group: 'Provider', address: '198.51.100.9', port: '8443', password: 'tr-pw',
			transport: 'ws', ws_host: 'cdn.example.net', ws_path: '/tr', tls: '1', tls_allowInsecure: '1' },
		{ '.name': 'C', '.type': 'nodes', protocol: 'vless', remarks: 'Japan', add_mode: '0' },
		{ '.name': 'G', '.type': 'nodes', protocol: '_urltest', remarks: 'Fastest', urltest_node: [ 'A', 'T' ] },
		{ '.name': 'WORK', '.type': 'shunt_rules', remarks: 'Work VPN' },
		{ '.name': 'RUSSIA', '.type': 'shunt_rules', remarks: 'RUSSIA' },
		{ '.name': 'PROXY', '.type': 'shunt_rules', remarks: 'PROXY' },
		{ '.name': 'QUIC', '.type': 'shunt_rules', remarks: 'QUIC' },
		{ '.name': 'UDP', '.type': 'shunt_rules', remarks: 'UDP' },
		Object.assign({ '.name': R, '.type': 'nodes', protocol: '_shunt', remarks: 'Main Router', default_node: def }, targets)
	];
}
const router = function() {
	const r = sec(R);
	return [ 'WORK', 'RUSSIA', 'PROXY', 'QUIC', 'UDP' ].map(function(k) { return k + '=' + (r[k] == null ? '' : r[k]); }).join(' ') + ' Default=' + r.default_node;
};
const use = function(sid) { return ev.setActiveTarget(sid, TEMPLATES); };

/* ---- a Trojan node is a server ---- */
setup(R, { WORK: 'C', RUSSIA: '_direct', PROXY: 'A', QUIC: 'A', UDP: '_blackhole' }, 'A');
check('Node List: Trojan nodes are servers, the Main Router and groups are not', ev.isServer('T') && ev.isServer('TS') && ev.isServer('A') && !ev.isServer(R) && !ev.isServer('G'));
check('Node List: servers() lists VLESS and Trojan in list order (' + ev.servers().map(function(s) { return s['.name']; }).join(',') + ')',
	ev.servers().map(function(s) { return s['.name']; }).join(',') == 'A,T,TS,C');
check('labels name the protocol', ev.label('T') == 'Trojan: Trojan NL' && ev.label('A') == 'VLESS: Finland' && ev.label('G') == 'URL Test group: Fastest');
check('a Trojan server is a valid target (main node, Default, rule target)', ev.isProxyTarget('T') && ev.isProxyTarget('TS'));
const values = [];
ev.addTargetValues({ value: function(k, v) { values.push(k + '=' + v); } }, true);
check('rule targets offer the Trojan servers (' + values.join(' | ') + ')', values.indexOf('T=Trojan: Trojan NL') > -1 && values.indexOf('TS=Trojan: Trojan sub') > -1 && values.indexOf('A=VLESS: Finland') > -1);
check('references: a Trojan server used by a group is reported', ev.references('T').join() == 'URL Test group: Fastest');
check('an unknown protocol is not a server', (function() { UCI.push({ '.name': 'X', '.type': 'nodes', protocol: 'vmess', remarks: 'x' }); const r = ev.isServer('X'); UCI.pop(); return !r; })());

/* ---- Use with a Trojan server ---- */
let ch = use('T');
check('Use Trojan: the targets of the selected server follow, unrelated targets are kept (' + router() + ')',
	router() == 'WORK=C RUSSIA=_direct PROXY=T QUIC=T UDP=_blackhole Default=T');
check('Use Trojan: reports what changed (' + ch.map(function(c) { return c.entry; }).join(',') + ')', ch.map(function(c) { return c.entry; }).join(',') == 'PROXY,QUIC,default'
	&& ch.every(function(c) { return c.before == 'A' && c.after == 'T'; }));
check('Use Trojan: the main node stays the Main Router, the Trojan server is the selected node', sec('global').node == R && ev.selectedNode() == 'T');
check('Use Trojan again: nothing to change', use('T').length == 0);
use('TS');
check('Use a Trojan subscription server (' + router() + ')', router() == 'WORK=C RUSSIA=_direct PROXY=TS QUIC=TS UDP=_blackhole Default=TS');
use('A');
check('Use VLESS after Trojan: back, nothing else touched (' + router() + ')', router() == 'WORK=C RUSSIA=_direct PROXY=A QUIC=A UDP=_blackhole Default=A');
setup(R, { WORK: 'T', RUSSIA: '_direct', PROXY: 'A', QUIC: 'A', UDP: 'A' }, 'A');
use('C');
check('a rule that points to another (Trojan) server is not overwritten (' + router() + ')', router() == 'WORK=T RUSSIA=_direct PROXY=C QUIC=C UDP=C Default=C');
setup('A', {}, '_direct');
use('T');
check('without the Main Router the Trojan server becomes the main node', sec('global').node == 'T' && sec(R).default_node == '_direct');
setup(R, { RUSSIA: '_direct' }, 'G');
use('T');
check('Use a Trojan server out of a URL Test group (' + router() + ')', sec(R).default_node == 'T');

/* ---- trojan:// URL (Copy) ---- */
setup(R, {}, 'A');
const params = function(url) {
	const q = {};
	url.replace(/^[^?]*\?/, '').replace(/#.*$/, '').split('&').forEach(function(p) { const i = p.indexOf('='); q[p.slice(0, i)] = decodeURIComponent(p.slice(i + 1)); });
	return q;
};
let u = ev.buildVlessUrl('T');
check('URL: trojan://password@host:port, the password is encoded (' + u.url + ')', /^trojan:\/\/p%40ss%20word%2F1@nl\.example\.net:443\?/.test(u.url) && /#Trojan%20NL$/.test(u.url));
let q = params(u.url);
check('URL: type, security and SNI', q.type == 'tcp' && q.security == 'tls' && q.sni == 'sni.example.net' && u.warnings.length == 0);
check('URL: no VLESS parameters (encryption, flow)', !('encryption' in q) && !('flow' in q));
u = ev.buildVlessUrl('TS');
q = params(u.url);
check('URL ws: host, path and allowInsecure (' + u.url + ')', /^trojan:\/\/tr-pw@198\.51\.100\.9:8443\?/.test(u.url) && q.type == 'ws' && q.host == 'cdn.example.net' && q.path == '/tr' && q.allowInsecure == '1');
sec('T').tls = '0';
check('URL: a Trojan server without TLS says security=none (a trojan:// link means TLS otherwise)', params(ev.buildVlessUrl('T').url).security == 'none');
sec('T').tls = '1';
sec('T').address = '2001:db8::1';
check('URL: IPv6 address in brackets', /@\[2001:db8::1\]:443\?/.test(ev.buildVlessUrl('T').url));
u = ev.buildVlessUrl('A');
q = params(u.url);
check('URL: VLESS is built as before (' + u.url + ')', u.url.indexOf('vless://' + UUID + '@fi.example.net:443?') == 0 && q.encryption == 'none' && q.flow == 'xtls-rprx-vision' && q.security == 'tls');
check('URL: the Main Router or a group has no URL', ev.buildVlessUrl(R).url === null && ev.buildVlessUrl('G').url === null);

/* hostile values stay data */
const EVIL = '<img src=x onerror=alert(1)>';
sec('T').remarks = EVIL;
sec('T').password = '"><script>alert(1)</script>#?&@';
sec('T').address = 'nl.example.net';
u = ev.buildVlessUrl('T');
check('URL: a hostile name and password are percent-encoded', u.url.indexOf('<') < 0 && u.url.indexOf('"') < 0 && (u.url.match(/@/g) || []).length == 1 && (u.url.match(/#/g) || []).length == 1);
check('URL: and decode back to the same password', decodeURIComponent(u.url.match(/^trojan:\/\/([^@]*)@/)[1]) == sec('T').password);
modals.length = 0;
ev.showVlessUrl('T');
check('URL dialog of a Trojan server: titled Trojan, the name is escaped', modals.length == 1 && /^Trojan URL/.test(modals[0].title) && modals[0].title.indexOf('<') < 0 && !modals[0].body.some(usesInnerHTML));
check('label and badge with a hostile Trojan name: text', ev.label('T') == 'Trojan: ' + EVIL && !usesInnerHTML(ev.badge(ev.label('T'), 'ok')));

/* ---- First Run Wizard: link check ---- */
const wizard = fs.readFileSync(path.join(res, 'view', 'easy_vless', 'wizard.js'), 'utf8');
const fn = function(name) {
	const m = wizard.match(new RegExp('^function ' + name + '\\([^)]*\\) \\{\\n[\\s\\S]*?^\\}$', 'm'));
	if (!m) throw new Error('wizard.js: function ' + name + ' not found');
	return m[0];
};
const detectInput = new Function(fn('trojanLinkError') + fn('linkError') + fn('detectInput') + 'return detectInput;')();
let d = detectInput('trojan://secret@nl.example.net:443?sni=sni.example.net#Name');
check('wizard: a trojan:// link is one server', d.kind == 'trojan' && d.error === null);
d = detectInput('  TROJAN://p%40ss@[2001:db8::1]:8443#v6  ');
check('wizard: scheme in capitals, IPv6 address', d.kind == 'trojan' && d.error === null);
d = detectInput('trojan://nl.example.net:443#no-password');
check('wizard: a Trojan link without password is refused with a reason (' + d.error + ')', d.kind == 'trojan' && /trojan:\/\/password@address:port/.test(d.error));
d = detectInput('trojan://secret@nl.example.net#no-port');
check('wizard: a Trojan link without port is refused', d.kind == 'trojan' && !!d.error);
d = detectInput('trojan://secret@nl.example.net:70000#port');
check('wizard: a port out of range is refused (' + d.error + ')', /between 1 and 65535/.test(d.error));
d = detectInput('vless://' + UUID + '@fi.example.net:443?security=none#x');
check('wizard: a vless:// link is checked as before', d.kind == 'vless' && d.error === null);
d = detectInput('vless://not-a-uuid@fi.example.net:443#x');
check('wizard: a bad UUID in a vless:// link is still refused', d.kind == 'vless' && /UUID/.test(d.error));
d = detectInput('https://provider.example/list');
check('wizard: an https:// link is a subscription', d.kind == 'sub' && d.error === null);
d = detectInput('ss://YWVzLTI1Ni1nY206cGFzcw@192.0.2.1:8388#ss');
check('wizard: another scheme is refused and names both protocols (' + d.error + ')', d.kind === null && /not supported/.test(d.error) && /VLESS and Trojan/.test(d.error));

/* ---- Node List editor ---- */
const servers = fs.readFileSync(path.join(res, 'view', 'easy_vless', 'servers.js'), 'utf8');
check('editor: protocol selector with VLESS and Trojan', /s\.option\(form\.ListValue, 'protocol'/.test(servers) && /o\.value\('trojan', 'Trojan'\)/.test(servers));
check('editor: the password field is masked and belongs to Trojan', /'password', _\('Password'\)\);\n\t\to\.modalonly = true;\n\t\to\.rmempty = false;\n\t\to\.password = true;\n\t\to\.depends\('protocol', 'trojan'\);/.test(servers));
check('editor: UUID and Flow belong to VLESS', /o\.password = true;\n\t\to\.depends\('protocol', 'vless'\);/.test(servers) && /o\.depends\(\{ protocol: 'vless', transport: 'tcp', tls: '1' \}\);/.test(servers));
check('editor: a Trojan server is always a sing-box node', /if \(value == 'trojan'\)\n\t\t\t\tuci\.set\(CONFIG, section_id, 'type', 'sing-box'\);/.test(servers));
check('Node List: rows are moved among all servers, not only VLESS', /ev\.moveSection\(sid, up, function\(s\) \{ return ev\.isServerProtocol\(s\.protocol\); \}\)/.test(servers));

console.log('\n===== Trojan views: ' + pass + ' passed, ' + fail + ' failed =====');
process.exit(fail ? 1 : 0);
