/*
 * Easy VLESS - Node List "Use" (0.9.0), regression test of ev.setActiveTarget /
 * ev.selectedNode in luci/htdocs/luci-static/resources/easy_vless/common.js
 * without a browser (same loader stand-ins as node-list-sort-test.js).
 *
 *   node tests/use-server-test.js      (static checks, CI "checks" job)
 *
 * The bug (0.8): with the Main Router as main node, "Use" wrote only
 * main_router.default_node. The rule targets (main_router.<rule id>) hold a
 * node id of their own - the First Run Wizard and "Add prepared rule" resolve
 * "@active" to the server selected at that time - so PROXY / QUIC / UDP kept
 * sending their traffic to the old server.
 *
 * The bug left in 0.9.0: "Use" moved only the entries equal to ONE previously
 * selected node (ev.selectedNode = Default). A configuration that 0.8 had
 * already split (Default on the new server, PROXY / QUIC / UDP on the old
 * one), or one where Default was changed on Main, was never healed: "Use"
 * kept moving Default alone. Now the node of the prepared "@active" rules
 * (manifest rule_templates) counts as previously selected as well.
 *
 * Covered: manual server, subscription server, URL Test group, "Use this
 * server" out of a group, the main node without the Main Router, Default
 * (Direct / Block are kept), rule targets (Direct, Block, "Default target",
 * Not used and a different server are kept), no dangling references, the
 * split configuration (with custom rules and a rule on a third server), the
 * committed result after a reload.
 */
'use strict';
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
function check(msg, cond) {
	if (cond) { pass++; console.log('PASS: ' + msg); }
	else { fail++; console.log('FAIL: ' + msg); }
}

/* LuCI stand-ins: an ordered UCI store with get / set / unset / add */
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
	return this.replace(/%[sd]/g, function() { return String(args[i++]); });
};
const baseclass = { extend: function(o) { return o; } };
const rpc = { declare: function() { return function() { return Promise.resolve({}); }; } };
const src = fs.readFileSync(path.join(__dirname, '..', 'luci', 'htdocs', 'luci-static', 'resources', 'easy_vless', 'common.js'), 'utf8');
const ev = new Function('baseclass', 'rpc', 'uci', 'ui', 'dom', src)(baseclass, rpc, uci, {}, {});

const R = 'main_router';
/* the prepared rules of the package: PROXY, QUIC and UDP have target "@active" */
const TEMPLATES = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'root', 'usr', 'share', 'easy_vless', 'resources', 'manifest.json'), 'utf8')).rule_templates;
const use = function(sid) { return ev.setActiveTarget(sid, TEMPLATES); };
/* The routing the First Run Wizard writes ("basic") for server A:
 * RUSSIA -> Direct, PROXY / QUIC / UDP -> A, Default -> A. */
function setup(node, targets, def) {
	UCI = [
		{ '.name': 'global', '.type': 'global', node: node },
		{ '.name': 'A', '.type': 'nodes', protocol: 'vless', remarks: 'Finland', add_mode: '0' },
		{ '.name': 'B', '.type': 'nodes', protocol: 'vless', remarks: 'Germany', add_mode: '0' },
		{ '.name': 'S', '.type': 'nodes', protocol: 'vless', remarks: 'Sub node', add_mode: '2', group: 'Provider' },
		{ '.name': 'G', '.type': 'nodes', protocol: '_urltest', remarks: 'Fastest', urltest_node: [ 'A', 'B' ] },
		{ '.name': 'RUSSIA', '.type': 'shunt_rules', remarks: 'RUSSIA' },
		{ '.name': 'PROXY', '.type': 'shunt_rules', remarks: 'PROXY' },
		{ '.name': 'QUIC', '.type': 'shunt_rules', remarks: 'QUIC' },
		{ '.name': 'UDP', '.type': 'shunt_rules', remarks: 'UDP' },
		Object.assign({ '.name': R, '.type': 'nodes', protocol: '_shunt', remarks: 'Main Router', default_node: def }, targets)
	];
}
const wizard = function(n, def) { setup(R, { RUSSIA: '_direct', PROXY: n, QUIC: n, UDP: n }, def == null ? n : def); };
const router = function() {
	const r = sec(R);
	return [ 'RUSSIA', 'PROXY', 'QUIC', 'UDP' ].map(function(k) { return k + '=' + (r[k] == null ? '' : r[k]); }).join(' ') + ' Default=' + r.default_node;
};
const entries = function(changed) { return changed.map(function(c) { return c.entry; }).join(','); };
/* every Main Router entry and the main node point to something that exists */
const intact = function() {
	const r = sec(R);
	const valid = function(t) { return !t || [ '_direct', '_blackhole', '_default' ].indexOf(t) > -1 || ev.isProxyTarget(t); };
	return uci.sections('', 'shunt_rules').every(function(x) { return valid(r[x['.name']]); }) && valid(r.default_node)
		&& (sec('global').node == R || valid(sec('global').node));
};

/* ---- the bug: wizard routing on A, Use B ---- */
wizard('A');
check('selected node of the wizard routing is A', ev.selectedNode() == 'A');
let ch = use('B');
check('Use B: PROXY, QUIC and UDP follow, not only Default (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC=B UDP=B Default=B');
check('Use B: reports the changed entries (' + entries(ch) + ')', entries(ch) == 'PROXY,QUIC,UDP,default');
check('Use B: before / after of each entry', ch.every(function(c) { return c.before == 'A' && c.after == 'B'; }));
check('Use B: the main node stays the Main Router', sec('global').node == R);
check('Use B: B is the selected node, A is no longer referenced', ev.selectedNode() == 'B' && ev.references('A').join() == 'URL Test group: Fastest');
check('Use B: names of the changed entries', ev.changedEntries(ch).join() == 'PROXY,QUIC,UDP,Default');
check('Use B again: nothing to change', use('B').length == 0 && router() == 'RUSSIA=_direct PROXY=B QUIC=B UDP=B Default=B');
check('no dangling reference', intact());

/* ---- Default must not change wrongly ---- */
wizard('A', '_direct');
check('Default Direct: the selected node is the one of the rules (A)', ev.selectedNode() == 'A');
ch = use('B');
check('Default Direct is kept, the rule targets move (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC=B UDP=B Default=_direct');
check('Default Direct: Default is not reported as changed', entries(ch) == 'PROXY,QUIC,UDP');
wizard('A', '_blackhole');
use('B');
check('Default Block is kept (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC=B UDP=B Default=_blackhole');

/* ---- rule targets that are not the selected node are kept ---- */
setup(R, { RUSSIA: '_direct', PROXY: 'A', QUIC: '_blackhole', UDP: '_default' }, 'A');
use('B');
check('Direct, Block and "Default target" rules are kept (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC=_blackhole UDP=_default Default=B');
setup(R, { RUSSIA: '_direct', PROXY: 'A', UDP: 'S' }, 'A');
use('B');
check('a rule on a different server (S) and an unused rule are kept (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC= UDP=S Default=B');
check('no dangling reference', intact());

/* ---- nothing uses a server yet: the server becomes Default ---- */
setup(R, { RUSSIA: '_direct', UDP: '_default' }, '_direct');
check('no server in use: no selected node', ev.selectedNode() == '');
ch = use('A');
check('no server in use: Use A sets Default (' + router() + ')', router() == 'RUSSIA=_direct PROXY= QUIC= UDP=_default Default=A' && entries(ch) == 'default');
UCI = [ { '.name': 'global', '.type': 'global', node: R }, { '.name': 'A', '.type': 'nodes', protocol: 'vless', remarks: 'Finland' } ];
use('A');
check('Main Router section missing: it is created with Default A', sec(R) && sec(R).protocol == '_shunt' && sec(R).default_node == 'A');

/* ---- server of a subscription ---- */
wizard('A');
use('S');
check('subscription server: same as a manual one (' + router() + ')', router() == 'RUSSIA=_direct PROXY=S QUIC=S UDP=S Default=S' && intact());

/* ---- URL Test group ---- */
wizard('A');
use('G');
check('Use group: the group replaces the server everywhere (' + router() + ')', router() == 'RUSSIA=_direct PROXY=G QUIC=G UDP=G Default=G');
check('Use group: the group is the selected node, its servers are "in group"', ev.selectedNode() == 'G' && ev.targetUses('G', 'A') && ev.targetUses('G', 'B'));
check('Use group: the group keeps its servers', sec('G').urltest_node.join() == 'A,B');
use('B');
check('"Use this server" out of the group: the server replaces the group (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC=B UDP=B Default=B' && intact());

/* ---- main node without the Main Router ---- */
setup('A', { RUSSIA: '_direct', PROXY: 'A', QUIC: 'A', UDP: 'A' }, 'A');
ch = use('B');
check('server as main node: Use B changes only the main node', sec('global').node == 'B' && entries(ch) == 'node' && router() == 'RUSSIA=_direct PROXY=A QUIC=A UDP=A Default=A');
check('server as main node: selected node is the main node', ev.selectedNode() == 'B');
setup('', {}, '_direct');
use('G');
check('no main node yet: Use sets it', sec('global').node == 'G' && ev.selectedNode() == 'G');

/* ---- the bug left in 0.9.0: Default and the prepared rules disagree ---- */
check('manifest: PROXY, QUIC and UDP are the "@active" prepared rules',
	TEMPLATES.filter(function(t) { return t.target == '@active'; }).map(function(t) { return t.remarks; }).join() == 'PROXY,QUIC,UDP');
/* what "Use B" of 0.8 left behind: Default moved, the rules stayed on A */
wizard('A', 'B');
check('split routing: the selected node is Default (B)', ev.selectedNode() == 'B');
ch = use('S');
check('split routing: Use S moves PROXY, QUIC and UDP too, not only Default (' + router() + ')', router() == 'RUSSIA=_direct PROXY=S QUIC=S UDP=S Default=S');
check('split routing: reports every changed entry with its own previous node (' + entries(ch) + ')', entries(ch) == 'PROXY,QUIC,UDP,default'
	&& ch.map(function(c) { return c.before; }).join() == 'A,A,A,B' && ch.every(function(c) { return c.after == 'S'; }));
check('split routing: neither old server is referenced by the Main Router', ev.references('A').join() == 'URL Test group: Fastest' && ev.references('B').join() == 'URL Test group: Fastest');
check('split routing: Use S again changes nothing', use('S').length == 0 && intact());
/* Use of the server Default already points to: the rules still have to follow */
wizard('A', 'B');
ch = use('B');
check('split routing: Use of the Default server moves the prepared rules (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC=B UDP=B Default=B' && entries(ch) == 'PROXY,QUIC,UDP');
/* a group in Default, the rules on a server */
wizard('A', 'G');
use('B');
check('split routing: group in Default, server in the rules (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC=B UDP=B Default=B');

/* ---- unrelated targets of a split routing are kept ---- */
const custom = function(targets, def) {
	setup(R, targets, def);
	UCI.splice(5, 0, { '.name': 'WORK', '.type': 'shunt_rules', remarks: 'Work VPN' });
	UCI.push({ '.name': 'C', '.type': 'nodes', protocol: 'vless', remarks: 'Japan', add_mode: '0' });
};
const work = function() { return 'WORK=' + (sec(R).WORK == null ? '' : sec(R).WORK) + ' ' + router(); };
/* custom rule (first in priority) on its own server, a prepared rule put on a third server by the user */
custom({ WORK: 'S', RUSSIA: '_direct', PROXY: 'A', QUIC: 'A', UDP: 'C' }, 'B');
ch = use('G');
check('split routing: a custom rule on another server and a prepared rule on a third server are kept (' + work() + ')',
	work() == 'WORK=S RUSSIA=_direct PROXY=G QUIC=G UDP=C Default=G' && entries(ch) == 'PROXY,QUIC,default');
check('no dangling reference', intact());
/* consistent routing with the same custom entries: nothing but the selected node moves */
custom({ WORK: 'S', RUSSIA: '_direct', PROXY: 'A', QUIC: '_blackhole', UDP: 'C' }, 'A');
use('B');
check('custom rule, Block and a third server are kept (' + work() + ')', work() == 'WORK=S RUSSIA=_direct PROXY=B QUIC=_blackhole UDP=C Default=B');
/* a custom rule on the selected node follows, a custom rule on the node of the prepared rules too */
custom({ WORK: 'B', RUSSIA: '_direct', PROXY: 'A', QUIC: 'A', UDP: 'A' }, 'B');
use('C');
check('custom rule on the selected node follows (' + work() + ')', work() == 'WORK=C RUSSIA=_direct PROXY=C QUIC=C UDP=C Default=C');
/* Default Direct, the first prepared rule is switched off: the next one names the node */
custom({ WORK: 'S', RUSSIA: '_direct', PROXY: '_direct', QUIC: 'A', UDP: 'A' }, '_direct');
use('B');
check('Default Direct and PROXY Direct are kept, QUIC / UDP move (' + work() + ')', work() == 'WORK=B RUSSIA=_direct PROXY=_direct QUIC=B UDP=B Default=_direct');
/* prepared rules renamed by remarks only: the rule is found by its name like "Add prepared rule" does */
wizard('A', 'B');
UCI.forEach(function(s) { if (s['.name'] == 'PROXY') { s['.name'] = 'rule_x1'; } });
sec(R).rule_x1 = sec(R).PROXY; delete sec(R).PROXY;
use('S');
check('prepared rule with a generated section id is found by its name', sec(R).rule_x1 == 'S' && sec(R).QUIC == 'S' && sec(R).default_node == 'S');
/* no templates (manifest not readable): the 0.9.0 behaviour, nothing unrelated is touched */
wizard('A', 'B');
ev.setActiveTarget('S');
check('without templates only the selected node is replaced (' + router() + ')', router() == 'RUSSIA=_direct PROXY=A QUIC=A UDP=A Default=S');

/* ---- saved result: what is committed is what a reload reads ---- */
wizard('A', 'B');
use('S');
UCI = JSON.parse(JSON.stringify(UCI));   /* a fresh load of the committed configuration */
check('after a reload S is the selected node and owns every prepared target (' + router() + ')',
	ev.selectedNode() == 'S' && router() == 'RUSSIA=_direct PROXY=S QUIC=S UDP=S Default=S' && use('S').length == 0);

console.log('\n===== Use server: ' + pass + ' passed, ' + fail + ' failed =====');
process.exit(fail ? 1 : 0);
