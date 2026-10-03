/*
 * Easy VLESS - Maintenance view (0.9.0), test of the texts of
 * luci/htdocs/.../view/easy_vless/maintenance.js without a browser.
 *
 *   node tests/maintenance-view-test.js      (static checks, CI "checks" job)
 *
 * Covered: every refusal the router can answer for a backup / import
 * (transfer.lua, backup.lua) and for an update (update.sh) has its own
 * text; the two file formats are told apart for the user; update states.
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
	toArray: function(x) { return x == null ? [] : (Array.isArray(x) ? x : [ x ]); },
	url: function(p) { return '/cgi-bin/luci/' + p; }
};
global._ = function(s) { return s; };
global.E = function(tag, attrs, children) { return { tag: tag, attrs: attrs, children: children }; };
let store = {};
global.window = { setTimeout: function() { return 1; }, sessionStorage: { getItem: function(k) { return store[k] || null; }, setItem: function(k, v) { store[k] = v; } } };
String.prototype.format = function() {
	const args = arguments;
	let i = 0;
	return this.replace(/%(\.\d+)?[sdf]/g, function() { return String(args[i++]); });
};
const root = path.join(__dirname, '..');
const res = path.join(root, 'luci', 'htdocs', 'luci-static', 'resources');
const baseclass = { extend: function(o) { return o; } };
const rpc = { declare: function() { return function() { return Promise.resolve({}); }; } };
const UCI = { global: {} };
const uci = { get: function(c, s, o) { return UCI[s] ? UCI[s][o] : null; }, sections: function() { return []; } };
const ev = new Function('baseclass', 'rpc', 'uci', 'ui', 'dom', fs.readFileSync(path.join(res, 'easy_vless', 'common.js'), 'utf8'))(baseclass, rpc, uci, {}, {});
const view = new Function('view', 'uci', 'ui', 'dom', 'poll', 'ev', fs.readFileSync(path.join(res, 'view', 'easy_vless', 'maintenance.js'), 'utf8'))(
	{ extend: function(o) { return o; } }, uci, {}, {}, {}, ev);

const text = function(e) { return view.transferError({ ok: false, error: e }); };

/* ---- the two formats are told apart ---- */
check('restore of an export file: says it is an export and where to use it', /export file \(Servers\), not a backup\. Use Import/.test(text({ code: 'not_backup', kind: 'nodes' })));
check('import of a backup file: says it is a backup and where to use it', /backup of the whole configuration.*Use Restore/.test(text({ code: 'not_export', backup: true })));
check('a foreign file', /not an Easy VLESS backup file/.test(text({ code: 'not_backup' })) && /not an Easy VLESS export file/.test(text({ code: 'not_export' })) && /not valid JSON/.test(text({ code: 'not_json' })));

/* ---- every refusal code of the router has its own text ---- */
const lua = fs.readFileSync(path.join(root, 'root', 'usr', 'lib', 'lua', 'luci', 'easy_vless', 'transfer.lua'), 'utf8')
	+ fs.readFileSync(path.join(root, 'root', 'usr', 'share', 'easy_vless', 'backup.lua'), 'utf8');
const codes = {};
let m;
const re1 = /err\("([a-z_]+)"/g, re2 = /code = "([a-z_]+)"/g;
while ((m = re1.exec(lua))) codes[m[1]] = true;
while ((m = re2.exec(lua))) codes[m[1]] = true;
const generic = text({ code: 'zzz_unknown' });
const missing = Object.keys(codes).filter(function(c) {
	if (c == 'internal' || c == 'action' || c == 'dangling')
		return false;
	const t = text({ code: c, kind: 'nodes', want: 'rules', line: 3, step: 'uci', version: 2 });
	return t == text({ code: 'zzz_unknown' }).replace('zzz_unknown', c);
});
check('transfer / backup error codes found (' + Object.keys(codes).length + ')', Object.keys(codes).length >= 20);
check('every refusal has its own text' + (missing.length ? ' - missing: ' + missing.join(', ') : ''), missing.length == 0);
check('an unknown code still names it (never a bare "failed")', /zzz_unknown/.test(generic));
check('refusals that change nothing say so', [ 'damaged', 'config_syntax', 'config_empty', 'no_global', 'hwid', 'direct_ip', 'rollback_copy' ].every(function(c) {
	return /Nothing was changed/.test(text({ code: c, line: 1 })); }));
check('a failed write names the step and that the old configuration is in place', /failed \(uci\)\. The previous configuration is still in place/.test(text({ code: 'apply', step: 'uci', restored: true })));
check('a failed restore whose undo also failed tells what to do', /Undo the last restore/.test(text({ code: 'apply', step: 'write', restored: false })));
check('busy: subscription update / service', /subscription update is running/.test(text({ code: 'busy', what: 'subscription' })) && /starting or stopping/.test(text({ code: 'busy', what: 'service' })));
check('kind mismatch names both kinds', text({ code: 'kind_mismatch', kind: 'rules', want: 'nodes' }) == 'The file contains Rules, not Servers.');
check('rpc failure', /did not answer: timeout/.test(view.transferError({ rpc_error: true, error: 'timeout' })));
check('skip reasons', view.skipReason({ reason: 'exists' }) == 'already exists' && view.skipReason({ reason: 'duplicate' }) == 'twice in the file' && view.skipReason({ reason: 'invalid', field: 'uuid' }) == 'invalid value: uuid');

/* ---- update ---- */
const sh = fs.readFileSync(path.join(root, 'root', 'usr', 'share', 'easy_vless', 'update.sh'), 'utf8');
const phases = {};
const re3 = /write_state ([a-z_]+) /g;
while ((m = re3.exec(sh))) phases[m[1]] = true;
const noText = Object.keys(phases).filter(function(p) { return view.updateHeadline({ phase: p, status: 'failed' }) === p; });
check('every update phase of update.sh (' + Object.keys(phases).join(', ') + ') has a headline' + (noText.length ? ' - missing: ' + noText.join(', ') : ''), Object.keys(phases).length >= 9 && noText.length == 0);
check('failed before the change: "nothing was installed"', [ 'verify', 'compatibility', 'backup' ].every(function(p) { return /Nothing was installed/.test(view.updateHeadline({ phase: p, status: 'failed' })); }));
check('rollback: says which version runs again', /rolled back: Easy VLESS 0\.9\.0-r1 is installed again/.test(view.updateHeadline({ phase: 'rolled_back', status: 'failed', version: '0.9.0-r1' })));
check('incomplete rollback is not presented as a rollback', /could not be put back completely/.test(view.updateHeadline({ phase: 'rollback_failed', status: 'failed' })));
check('finished states', view.updateFinished({ phase: 'done', status: 'ok' }) && view.updateFinished({ phase: 'verify', status: 'failed' }) && view.updateFinished({ phase: 'rolled_back', status: 'failed' })
	&& !view.updateFinished({ phase: 'install', status: 'running' }) && !view.updateFinished({ phase: 'download', status: 'running' }));
const errs = {};
const re4 = /fail ([a-z_]+) "/g;
while ((m = re4.exec(sh))) errs[m[1]] = true;
check('check errors of update.sh (' + Object.keys(errs).join(', ') + ') have a text', Object.keys(errs).length == 3 && Object.keys(errs).every(function(c) {
	return view.updateError({ ok: false, error: c, current: '0.9.0-r1', detail: 'd' }).indexOf('refused the request') < 0; }));
check('unreachable GitHub is not reported as "up to date"', /not known whether there is a newer version/.test(view.updateError({ ok: false, error: 'network' })));

/* ---- update notice ---- */
check('notice: shown for a newer version', ev.updateNotice({ ok: true, available: true, latest: '0.9.1-r1', current: '0.9.0-r1' }) !== '');
check('notice: nothing when up to date, on an error, or without a result', ev.updateNotice({ ok: true, available: false }) === '' && ev.updateNotice({ ok: false, error: 'network' }) === '' && ev.updateNotice(null) === '');
ev.setUpdateDismissed('0.9.1-r1');
check('notice: "Later" hides this version for the session, a newer one is shown again', ev.updateNotice({ ok: true, available: true, latest: '0.9.1-r1', current: '0.9.0-r1' }) === ''
	&& ev.updateNotice({ ok: true, available: true, latest: '0.9.2-r1', current: '0.9.0-r1' }) !== '');
check('automatic check: on by default, off with update_check = 0', ev.updateCheckEnabled() === true && (UCI.global.update_check = '0', ev.updateCheckEnabled() === false));
const notice = JSON.stringify(ev.updateNotice({ ok: true, available: true, latest: '0.9.2-r1', current: '0.9.0-r1' }));
check('notice: Update is a link to Maintenance (the update is confirmed there)', /"href":"[^"]*easy_vless\/maintenance"/.test(notice));

console.log('\n===== Maintenance view: ' + pass + ' passed, ' + fail + ' failed =====');
process.exit(fail ? 1 : 0);
