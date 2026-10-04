/*
 * Easy VLESS 1.0 - text shown by the LuCI pages is text, not HTML.
 *
 *   node tests/html-safety-test.js      (static checks, CI "checks" job)
 *
 * LuCI's E(tag, attrs, data) inserts a string given as data with innerHTML,
 * and so do the title of a modal dialog, the title of a form option and the
 * text of a table cell. The name of a server comes from a subscription or a
 * pasted link, a rule from an imported file: a "<" in it must be shown, never
 * interpreted. Covered: ev.E (used by common.js and every view), ev.esc, and
 * that every view really uses them where LuCI inserts HTML.
 */
'use strict';
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
function check(msg, cond) {
	if (cond) { pass++; console.log('PASS: ' + msg); }
	else { fail++; console.log('FAIL: ' + msg); }
}

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

const root = path.join(__dirname, '..');
const res = path.join(root, 'luci', 'htdocs', 'luci-static', 'resources');
const EVIL = '<img src=x onerror=alert(1)>';
const store = { global: { '.type': 'global', node: 'main_router' },
	srv: { '.type': 'nodes', '.name': 'srv', protocol: 'vless', remarks: EVIL, address: '192.0.2.1', port: '443' } };
const uci = {
	get: function(c, s, o) { const sec = store[s]; return sec ? (o ? sec[o] : sec) : null; },
	sections: function(c, t) { return Object.keys(store).map(function(k) { return store[k]; }).filter(function(s) { return s['.type'] == t; }); }
};
const modals = [];
const ui = { showModal: function(title, body) { modals.push({ title: title, body: body }); }, hideModal: function() {}, addNotification: function(t, node) { modals.push({ note: node }); } };
const ev = new Function('baseclass', 'rpc', 'uci', 'ui', 'dom', fs.readFileSync(path.join(res, 'easy_vless', 'common.js'), 'utf8'))(
	{ extend: function(o) { return o; } }, { declare: function() { return function() { return Promise.resolve({}); }; } }, uci, ui, {});

/* ---- ev.E ---- */
let el = ev.E('p', {}, EVIL);
check('ev.E: a string is appended as text, not as HTML', !usesInnerHTML(el) && el.children.length == 1 && el.children[0].text == EVIL);
el = ev.E('p', EVIL);
check('ev.E: also without an attribute object', !usesInnerHTML(el) && el.children[0].text == EVIL);
el = ev.E('td', { 'class': 'td' }, 5);
check('ev.E: numbers are text', !usesInnerHTML(el) && el.children[0].text == '5');
el = ev.E('div', { 'id': 'x' }, [ 'a', ev.E('b', {}, 'c') ]);
check('ev.E: arrays and nodes are passed on', !usesInnerHTML(el) && el.children.length == 2 && el.attrs.id == 'x' && el.children[1].tag == 'b');
el = ev.E('div', {}, ev.E('span', {}, 'x'));
check('ev.E: a node as data stays a node', el.children.length == 1 && el.children[0].tag == 'span');
check('ev.E: no data', !usesInnerHTML(ev.E('br')) && !usesInnerHTML(ev.E('div', { 'id': 'y' })));
check('plain LuCI E would have inserted the string as HTML (what this test guards against)', usesInnerHTML(luciE('p', {}, EVIL)));

/* ---- ev.esc ---- */
check('ev.esc: markup characters are escaped', ev.esc(EVIL).indexOf('<') < 0 && ev.esc(EVIL).indexOf('>') < 0 && /&#60;img/.test(ev.esc(EVIL)));
check('ev.esc: null is an empty text', ev.esc(null) === '' && ev.esc(undefined) === '');

/* ---- common.js with a hostile server name ---- */
check('badge with a hostile name: text', !usesInnerHTML(ev.badge(ev.label('srv'), 'ok')));
modals.length = 0;
ev.showResult('Test', 'bad', EVIL, 'log line with ' + EVIL);
check('result dialog: headline and details are text', modals.length == 1 && !modals[0].body.some(usesInnerHTML));
modals.length = 0;
ev.notify('Server ' + EVIL + ' deleted.');
check('notification: text', modals.length == 1 && !usesInnerHTML(modals[0].note));
modals.length = 0;
ev.showVlessUrl('srv');
check('VLESS URL dialog: the title is escaped (LuCI inserts a title as HTML)', modals.length == 1 && modals[0].title.indexOf('<') < 0 && !modals[0].body.some(usesInnerHTML));

/* ---- every view ---- */
const viewDir = path.join(res, 'view', 'easy_vless');
fs.readdirSync(viewDir).filter(function(f) { return /\.js$/.test(f); }).forEach(function(f) {
	const src = fs.readFileSync(path.join(viewDir, f), 'utf8');
	check(f + ': uses the text-safe E of common.js', /^const E = ev\.E;$/m.test(src));
	/* titles LuCI inserts as HTML: a modal title with a name of the configuration */
	const titles = src.split('\n').filter(function(l, i, all) { return i > 0 && /\.modaltitle = function/.test(all[i - 1]); });
	check(f + ': modal titles with names are escaped (' + titles.length + ')', titles.every(function(l) { return /return ev\.esc\(/.test(l); }));
	/* innerHTML only for the translated help texts of the rule editor */
	const inner = src.split('\n').filter(function(l) { return /\.innerHTML\s*=/.test(l); });
	check(f + ': no innerHTML with data (' + inner.length + ')', inner.every(function(l) { return /d\.innerHTML = def\.help/.test(l); }));
});
const common = fs.readFileSync(path.join(res, 'easy_vless', 'common.js'), 'utf8');
check('common.js: innerHTML only for the generated QR code', common.split('\n').filter(function(l) { return /\.innerHTML\s*=/.test(l); }).every(function(l) { return /uqr\.renderSVG/.test(l); }));
const main = fs.readFileSync(path.join(viewDir, 'main.js'), 'utf8');
check('main.js: a rule name as option title is escaped', /'\* ' \+ ev\.esc\(r\.remarks \|\| rid\)/.test(main));
const servers = fs.readFileSync(path.join(viewDir, 'servers.js'), 'utf8');
check('servers.js: an unknown transport name in the table is escaped', /\[v\] \|\| ev\.esc\(v\)/.test(servers));

console.log('\n===== HTML safety: ' + pass + ' passed, ' + fail + ' failed =====');
process.exit(fail ? 1 : 0);
