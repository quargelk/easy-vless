/*
 * Easy VLESS - Node List latency state and sorting (0.8.0), unit test of
 * luci/htdocs/luci-static/resources/easy_vless/common.js without a browser:
 * the file is evaluated the way LuCI's loader does (a function body with its
 * 'require'd classes as arguments), with minimal stand-ins for LuCI.
 *
 *   node tests/node-list-sort-test.js      (static checks, CI "checks" job)
 *
 * Covered: testInfo (passed / failed / not tested / testing / queued, a
 * result of another address is not used), compareNodes / sortRecords (by
 * latency: failed and untested never count as "0 ms" and come after the
 * passed ones; stable order for equal values; by name, status, last test,
 * list order), setTestState (results of the rpcd "test state" answer).
 */
'use strict';
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
function check(msg, cond) {
	if (cond) { pass++; console.log('PASS: ' + msg); }
	else { fail++; console.log('FAIL: ' + msg); }
}

/* LuCI stand-ins */
const UCI = {};
const uci = {
	get: function(conf, sid, opt) {
		const s = UCI[sid];
		if (!s) return null;
		return opt == null ? s : (s[opt] == null ? null : s[opt]);
	},
	sections: function(conf, type) {
		return Object.keys(UCI).filter(function(k) { return UCI[k]['.type'] == type; }).map(function(k) { return UCI[k]; });
	}
};
const L = {
	bind: function(fn, self) { const a = Array.prototype.slice.call(arguments, 2); return function() { return fn.apply(self, a.concat(Array.prototype.slice.call(arguments))); }; },
	toArray: function(x) { return x == null ? [] : (Array.isArray(x) ? x : [ x ]); }
};
global.L = L;
global._ = function(s) { return s; };
global.E = function(tag, attrs, children) { return { tag: tag, attrs: attrs, children: children }; };
global.window = { setTimeout: function() { return 1; } };
String.prototype.format = function() {
	const args = arguments;
	let i = 0;
	return this.replace(/%[sd]/g, function() { return String(args[i++]); });
};
const baseclass = { extend: function(o) { return o; } };
const rpc = { declare: function() { return function() { return Promise.resolve({}); }; } };

const src = fs.readFileSync(path.join(__dirname, '..', 'luci', 'htdocs', 'luci-static', 'resources', 'easy_vless', 'common.js'), 'utf8');
const ev = new Function('baseclass', 'rpc', 'uci', 'ui', 'dom', src)(baseclass, rpc, uci, {}, {});

function server(id, name, address, port) {
	UCI[id] = { '.name': id, '.type': 'nodes', protocol: 'vless', remarks: name, address: address, port: String(port) };
}
server('a', 'Alpha', '192.0.2.1', 443);
server('b', 'Bravo', '192.0.2.2', 443);
server('c', 'Charlie', '192.0.2.3', 443);
server('d', 'Delta', '192.0.2.4', 443);
server('e', 'echo', '192.0.2.5', 443);
server('f', 'Foxtrot', '192.0.2.6', 443);
server('g', 'Golf 10', '192.0.2.7', 443);
server('h', 'Golf 9', '192.0.2.8', 443);

const res = function(node, kind, ok, delay, time, address) {
	return { node: node, result: { kind: kind, ok: ok, delay: delay, time: time, address: address || UCI[node].address, port: UCI[node].port, error_kind: ok ? undefined : 'timeout' } };
};
ev.setTestState({
	ok: true, now: 1000, running: true, total: 3, done: 1,
	current: { kind: 'server', node: 'e', since: 990 },
	queue: [ { kind: 'server', node: 'f' } ],
	results: [
		res('a', 'server', true, 350, 900),
		res('b', 'server', true, 120, 950),
		res('c', 'server', false, 0, 980),
		res('d', 'server', true, 120, 800),
		res('e', 'server', true, 40, 700),
		res('g', 'server', true, 50, 600, '198.51.100.9'),   /* made for an older address */
		res('a', 'url', false, 0, 990)
	]
});

/* ---- test state of one server ---- */
check('passed result: state passed', ev.testInfo('a', 'server').state == 'passed');
check('failed result: state failed, the result is kept', ev.testInfo('c', 'server').state == 'failed' && ev.testInfo('c', 'server').result.ok === false);
check('running test: state testing, the last result still available', ev.testInfo('e', 'server').state == 'testing' && ev.testInfo('e', 'server').result.delay == 40);
check('queued test without a result: state queued', ev.testInfo('f', 'server').state == 'queued' && ev.testInfo('f', 'server').result == null);
check('no result: state none (not tested)', ev.testInfo('h', 'server').state == 'none');
check('result for another address (edited server): not used', ev.testInfo('g', 'server').state == 'none' && ev.testInfo('g', 'server').result == null);
check('Server Test and URL Test are separate', ev.testInfo('a', 'url').state == 'failed' && ev.testInfo('a', 'server').state == 'passed');
check('busy = testing or queued', ev.testBusy('e', 'server') && ev.testBusy('f', 'server') && !ev.testBusy('a', 'server'));
check('state of the whole run', ev.testState.running && ev.testState.total == 3 && ev.testState.done == 1);

/* ---- sorting ---- */
const ids = [ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' ];
const recs = ids.map(function(id, i) { return ev.sortRecord(id, i); });
const order = function(mode) { return ev.sortRecords(recs, mode).map(function(r) { return r.id; }).join(''); };

check('sort record: failed has no latency (never 0 ms)', ev.sortRecord('c', 2).delay === null && ev.sortRecord('c', 2).state == 'failed');
check('sort record: not tested has no latency', ev.sortRecord('h', 7).delay === null && ev.sortRecord('h', 7).state == 'none');
/* latency: e 40, b 120 = d 120 (by name: Bravo, Delta), a 350; failed c; untested f, g, h by name (Foxtrot, Golf 9, Golf 10) */
check('latency: fastest first, equal latency by name, then failed, then untested (' + order('latency') + ')', order('latency') == 'ebdacfhg');
check('latency: a failed server is after every passed one', order('latency').indexOf('c') > order('latency').indexOf('a'));
check('name: case-insensitive, numbers in natural order (' + order('name') + ')', order('name') == 'abcdefhg');
check('status: passed, failed, not tested - each by name (' + order('status') + ')', order('status') == 'abdecfhg');
check('last test: newest first, untested last (' + order('time') + ')', order('time') == 'cbadefhg');
check('list order: the UCI order', order('default') == 'abcdefgh');
check('unknown mode: the UCI order', order('nonsense') == 'abcdefgh');
check('sorting does not change the input', recs.map(function(r) { return r.id; }).join('') == 'abcdefgh');
const shuffled = [ recs[3], recs[1], recs[7], recs[0], recs[6], recs[2], recs[5], recs[4] ];
check('stable: the same order from any input order', ev.sortRecords(shuffled, 'latency').map(function(r) { return r.id; }).join('') == order('latency'));
const twins = [ { id: 'x', name: 'Same', order: 5, state: 'passed', delay: 80, time: 1 }, { id: 'y', name: 'Same', order: 2, state: 'passed', delay: 80, time: 1 } ];
check('equal name and latency: UCI order decides', ev.sortRecords(twins, 'latency').map(function(r) { return r.id; }).join('') == 'yx');

/* ---- a test finishes: sorting reflects the new result right away ---- */
ev.setTestState({ ok: true, now: 1010, running: false, total: 3, done: 3, queue: [],
	results: [ res('a', 'server', true, 350, 900), res('b', 'server', true, 120, 950), res('c', 'server', false, 0, 980),
		res('d', 'server', true, 120, 800), res('e', 'server', true, 40, 700), res('f', 'server', true, 10, 1005) ] });
const recs2 = ids.map(function(id, i) { return ev.sortRecord(id, i); });
check('new result: Foxtrot (10 ms) sorts first', ev.sortRecords(recs2, 'latency')[0].id == 'f');
check('finished run: nothing testing or queued', !ids.some(function(id) { return ev.testBusy(id, 'server'); }));
check('an rpc error does not replace the known state', ev.setTestState({ rpc_error: true }).results.f.server.delay == 10);

/* ---- failure reasons ---- */
check('failure reason: translated text by error_kind', /timeout/i.test(ev.testError({ ok: false, error_kind: 'timeout' })));
check('failure reason: busy (lock timeout) is explained', /another Easy VLESS operation/.test(ev.testError({ ok: false, error_kind: 'busy' })));

console.log('\n===== Node List sorting: ' + pass + ' passed, ' + fail + ' failed =====');
process.exit(fail ? 1 : 0);
