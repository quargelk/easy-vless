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
 * Covered: manual server, subscription server, URL Test group, "Use this
 * server" out of a group, the main node without the Main Router, Default
 * (Direct / Block are kept), rule targets (Direct, Block, "Default target",
 * Not used and a different server are kept), no dangling references.
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
let ch = ev.setActiveTarget('B');
check('Use B: PROXY, QUIC and UDP follow, not only Default (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC=B UDP=B Default=B');
check('Use B: reports the changed entries (' + entries(ch) + ')', entries(ch) == 'PROXY,QUIC,UDP,default');
check('Use B: before / after of each entry', ch.every(function(c) { return c.before == 'A' && c.after == 'B'; }));
check('Use B: the main node stays the Main Router', sec('global').node == R);
check('Use B: B is the selected node, A is no longer referenced', ev.selectedNode() == 'B' && ev.references('A').join() == 'URL Test group: Fastest');
check('Use B: names of the changed entries', ev.changedEntries(ch).join() == 'PROXY,QUIC,UDP,Default');
check('Use B again: nothing to change', ev.setActiveTarget('B').length == 0 && router() == 'RUSSIA=_direct PROXY=B QUIC=B UDP=B Default=B');
check('no dangling reference', intact());

/* ---- Default must not change wrongly ---- */
wizard('A', '_direct');
check('Default Direct: the selected node is the one of the rules (A)', ev.selectedNode() == 'A');
ch = ev.setActiveTarget('B');
check('Default Direct is kept, the rule targets move (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC=B UDP=B Default=_direct');
check('Default Direct: Default is not reported as changed', entries(ch) == 'PROXY,QUIC,UDP');
wizard('A', '_blackhole');
ev.setActiveTarget('B');
check('Default Block is kept (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC=B UDP=B Default=_blackhole');

/* ---- rule targets that are not the selected node are kept ---- */
setup(R, { RUSSIA: '_direct', PROXY: 'A', QUIC: '_blackhole', UDP: '_default' }, 'A');
ev.setActiveTarget('B');
check('Direct, Block and "Default target" rules are kept (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC=_blackhole UDP=_default Default=B');
setup(R, { RUSSIA: '_direct', PROXY: 'A', UDP: 'S' }, 'A');
ev.setActiveTarget('B');
check('a rule on a different server (S) and an unused rule are kept (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC= UDP=S Default=B');
check('no dangling reference', intact());

/* ---- nothing uses a server yet: the server becomes Default ---- */
setup(R, { RUSSIA: '_direct', UDP: '_default' }, '_direct');
check('no server in use: no selected node', ev.selectedNode() == '');
ch = ev.setActiveTarget('A');
check('no server in use: Use A sets Default (' + router() + ')', router() == 'RUSSIA=_direct PROXY= QUIC= UDP=_default Default=A' && entries(ch) == 'default');
UCI = [ { '.name': 'global', '.type': 'global', node: R }, { '.name': 'A', '.type': 'nodes', protocol: 'vless', remarks: 'Finland' } ];
ev.setActiveTarget('A');
check('Main Router section missing: it is created with Default A', sec(R) && sec(R).protocol == '_shunt' && sec(R).default_node == 'A');

/* ---- server of a subscription ---- */
wizard('A');
ev.setActiveTarget('S');
check('subscription server: same as a manual one (' + router() + ')', router() == 'RUSSIA=_direct PROXY=S QUIC=S UDP=S Default=S' && intact());

/* ---- URL Test group ---- */
wizard('A');
ev.setActiveTarget('G');
check('Use group: the group replaces the server everywhere (' + router() + ')', router() == 'RUSSIA=_direct PROXY=G QUIC=G UDP=G Default=G');
check('Use group: the group is the selected node, its servers are "in group"', ev.selectedNode() == 'G' && ev.targetUses('G', 'A') && ev.targetUses('G', 'B'));
check('Use group: the group keeps its servers', sec('G').urltest_node.join() == 'A,B');
ev.setActiveTarget('B');
check('"Use this server" out of the group: the server replaces the group (' + router() + ')', router() == 'RUSSIA=_direct PROXY=B QUIC=B UDP=B Default=B' && intact());

/* ---- main node without the Main Router ---- */
setup('A', { RUSSIA: '_direct', PROXY: 'A', QUIC: 'A', UDP: 'A' }, 'A');
ch = ev.setActiveTarget('B');
check('server as main node: Use B changes only the main node', sec('global').node == 'B' && entries(ch) == 'node' && router() == 'RUSSIA=_direct PROXY=A QUIC=A UDP=A Default=A');
check('server as main node: selected node is the main node', ev.selectedNode() == 'B');
setup('', {}, '_direct');
ev.setActiveTarget('G');
check('no main node yet: Use sets it', sec('global').node == 'G' && ev.selectedNode() == 'G');

console.log('\n===== Use server: ' + pass + ' passed, ' + fail + ' failed =====');
process.exit(fail ? 1 : 0);
