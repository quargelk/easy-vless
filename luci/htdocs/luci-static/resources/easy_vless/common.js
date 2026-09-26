'use strict';
'require baseclass';
'require rpc';
'require uci';
'require ui';
'require dom';

/*
 * Easy VLESS - helpers shared by the LuCI views
 * (Main, Node List, Rule Manage, Settings).
 *
 * UCI model (the existing easy-vless runtime schema, PassWall2-derived):
 *   easy_vless.global.enabled       main switch
 *   easy_vless.global.node          what the runtime starts: a server, a URL
 *                                   Test group, or the Main Router (shunt)
 *   config nodes, protocol=vless    a VLESS server
 *   config nodes, protocol=_urltest a URL Test group (list urltest_node)
 *   config nodes 'main_router',     the Main Router ("_shunt" node):
 *     protocol=_shunt                 default_node = Default target,
 *                                     option <rule id> = target of that rule
 *   config shunt_rules              one rule = conditions only (remarks,
 *                                   protocol, inbound, network, source,
 *                                   sourcePort, port, domain_list, ip_list);
 *                                   section order = rule priority
 *   config subscribe_list           one subscription (subscribe.lua)
 *
 * Targets: '_direct' (Direct), '_blackhole' (Block), '_default' (rules only:
 * same as Default), a server id or a URL Test group id.
 */

const CONFIG = 'easy_vless';
const ROUTER = 'main_router';
const SERVER_TEST_URL = 'https://www.gstatic.com/generate_204';
const URL_TEST_URL = 'https://x.com';

const callStatus = rpc.declare({ object: 'luci.easy_vless', method: 'status', params: [ 'log_from' ], expect: { '': {} } });
const callCheck = rpc.declare({ object: 'luci.easy_vless', method: 'check', params: [ 'node' ], expect: { '': {} } });
const callStart = rpc.declare({ object: 'luci.easy_vless', method: 'start', expect: { '': {} } });
const callStop = rpc.declare({ object: 'luci.easy_vless', method: 'stop', expect: { '': {} } });
const callImport = rpc.declare({ object: 'luci.easy_vless', method: 'import', params: [ 'links' ], expect: { '': {} } });
const callSubscribe = rpc.declare({ object: 'luci.easy_vless', method: 'subscribe', params: [ 'action', 'id' ], expect: { '': {} } });
const callUrltestNode = rpc.declare({ object: 'luci.easy_vless', method: 'urltest_node', params: [ 'node', 'url' ], expect: { '': {} } });
const callResources = rpc.declare({ object: 'luci.easy_vless', method: 'resources', expect: { '': {} } });
const callGroups = rpc.declare({ object: 'luci.easy_vless', method: 'groups', expect: { '': {} } });
const callGroupTest = rpc.declare({ object: 'luci.easy_vless', method: 'group_test', params: [ 'group' ], expect: { '': {} } });
/* Requires "ubus": { "uci": [ "commit" ] } in the ACL (luci-base does not
 * grant it; without it every save silently failed - see current-state.md). */
const callUciCommit = rpc.declare({ object: 'uci', method: 'commit', params: [ 'config' ] });

function sleep(ms) {
	return new Promise(function(resolve) { window.setTimeout(resolve, ms); });
}

/* Never let an RPC failure (ACL, timeout, rpcd error) disappear: turn it
 * into a normal result object with the error text. */
function safe(promise) {
	return Promise.resolve(promise).catch(function(e) {
		return { ok: false, code: -1, rpc_error: true, error: (e && e.message) ? e.message : String(e), output: _('RPC error: %s').format((e && e.message) ? e.message : String(e)) };
	});
}

function lines(v) {
	return (v || '').split(/\r?\n/).map(function(l) { return l.trim(); }).filter(function(l) { return l && l.charAt(0) != '#'; });
}

return baseclass.extend({
	CONFIG: CONFIG,
	ROUTER: ROUTER,
	SERVER_TEST_URL: SERVER_TEST_URL,
	URL_TEST_URL: URL_TEST_URL,

	sleep: sleep,
	safe: safe,
	lines: lines,

	callStatus: function(logFrom) { return safe(callStatus(logFrom || 0)); },
	callCheck: function(node) { return safe(callCheck(node || '')); },
	callImport: function(links) { return safe(callImport(links)); },
	callSubscribe: function(action, id) { return safe(callSubscribe(action, id || '')); },
	callUrltestNode: function(sid, url) { return safe(callUrltestNode(sid, url || '')); },
	callResources: function() { return safe(callResources()); },
	callGroups: function() { return safe(callGroups()); },
	callGroupTest: function(id) { return safe(callGroupTest(id)); },

	/* Ports field: comma separated ports or from:to ranges, 1-65535. */
	validPorts: function(v) {
		return !v || String(v).split(',').every(function(p) {
			const m = p.match(/^(\d+)(?::(\d+))?$/);
			if (!m)
				return false;
			const a = +m[1], b = m[2] ? +m[2] : a;
			return a >= 1 && b <= 65535 && a <= b;
		});
	},

	/* ---------- node helpers ---------- */

	get: function(sid, opt) {
		return uci.get(CONFIG, sid, opt);
	},

	protocolOf: function(sid) {
		return uci.get(CONFIG, sid, 'protocol');
	},

	isServer: function(sid) {
		return this.protocolOf(sid) == 'vless';
	},

	isGroup: function(sid) {
		return this.protocolOf(sid) == '_urltest';
	},

	servers: function() {
		return uci.sections(CONFIG, 'nodes').filter(function(s) { return s.protocol == 'vless'; });
	},

	groups: function() {
		return uci.sections(CONFIG, 'nodes').filter(function(s) { return s.protocol == '_urltest'; });
	},

	rules: function() {
		return uci.sections(CONFIG, 'shunt_rules');
	},

	/* Random named section id: stable across saves and reordering (anonymous
	 * sections get a temporary id until the first save). */
	newName: function(prefix) {
		const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
		let n = prefix || '';
		for (let i = 0; i < 8; i++)
			n += chars.charAt(Math.floor(Math.random() * chars.length));
		return n;
	},

	label: function(sid) {
		if (!sid)
			return _('none');
		if (sid == '_direct')
			return _('Direct');
		if (sid == '_blackhole')
			return _('Block');
		if (sid == '_default')
			return _('Default target');
		const remarks = uci.get(CONFIG, sid, 'remarks');
		if (this.isGroup(sid))
			return _('URL Test group') + ': ' + (remarks || sid);
		if (this.isServer(sid))
			return 'VLESS: ' + (remarks || sid);
		if (sid == ROUTER)
			return _('Main Router (shunt)');
		return remarks || sid;
	},

	/* Target values for a ListValue: Direct, servers, groups, Block
	 * (+ "Default target" for rule entries). */
	addTargetValues: function(o, forRule) {
		if (forRule)
			o.value('_default', _('Default target'));
		o.value('_direct', _('Direct'));
		this.servers().forEach(L.bind(function(s) { o.value(s['.name'], this.label(s['.name'])); }, this));
		this.groups().forEach(L.bind(function(s) { o.value(s['.name'], this.label(s['.name'])); }, this));
		o.value('_blackhole', _('Block (blackhole)'));
	},

	shuntEnabled: function() {
		return uci.get(CONFIG, 'global', 'node') == ROUTER;
	},

	ensureRouter: function() {
		if (!uci.get(CONFIG, ROUTER)) {
			uci.add(CONFIG, 'nodes', ROUTER);
			uci.set(CONFIG, ROUTER, 'remarks', 'Main Router');
			uci.set(CONFIG, ROUTER, 'type', 'sing-box');
			uci.set(CONFIG, ROUTER, 'protocol', '_shunt');
			uci.set(CONFIG, ROUTER, 'default_node', '_direct');
		}
	},

	/* "Active target" = where default traffic goes: global.node, or the
	 * Main Router's Default target while the shunt is the main node. */
	activeTarget: function() {
		const node = uci.get(CONFIG, 'global', 'node');
		if (node == ROUTER)
			return uci.get(CONFIG, ROUTER, 'default_node') || '_direct';
		return node || '';
	},

	/* "Use": with the Main Router active, a server/group becomes its Default
	 * target (rule entries are kept); otherwise it becomes the main node. */
	setActiveTarget: function(sid) {
		if (this.shuntEnabled())
			uci.set(CONFIG, ROUTER, 'default_node', sid);
		else
			uci.set(CONFIG, 'global', 'node', sid);
	},

	/* Is a server used by the configuration (directly, via a group or as a
	 * Main Router target)? Returns a list of human readable references. */
	references: function(sid) {
		const refs = [];
		if (uci.get(CONFIG, 'global', 'node') == sid)
			refs.push(_('Main node'));
		if (uci.get(CONFIG, ROUTER, 'default_node') == sid)
			refs.push(_('Main Router: Default'));
		this.rules().forEach(L.bind(function(r) {
			if (uci.get(CONFIG, ROUTER, r['.name']) == sid)
				refs.push(_('Main Router: %s').format(r.remarks || r['.name']));
		}, this));
		this.groups().forEach(L.bind(function(g) {
			if (g['.name'] != sid && L.toArray(g.urltest_node).indexOf(sid) > -1)
				refs.push(this.label(g['.name']));
		}, this));
		return refs;
	},

	targetUses: function(target, sid) {
		if (!target)
			return false;
		if (target == sid)
			return true;
		if (this.isGroup(target))
			return L.toArray(uci.get(CONFIG, target, 'urltest_node')).indexOf(sid) > -1;
		return false;
	},

	/* Move a section one step up/down among the sections accepted by filter
	 * (UCI section order = display order; for rules = priority). */
	moveSection: function(sid, up, filter) {
		const list = uci.sections(CONFIG, uci.get(CONFIG, sid)['.type']).filter(filter || function() { return true; });
		const i = list.findIndex(function(s) { return s['.name'] == sid; });
		const j = up ? i - 1 : i + 1;
		if (i < 0 || j < 0 || j >= list.length)
			return false;
		return uci.move(CONFIG, sid, list[j]['.name'], !up);
	},

	/* ---------- result / busy UI ---------- */

	badge: function(text, kind) {
		const colors = { ok: '#2e7d32', bad: '#c62828', warn: '#b26a00', idle: '#607d8b', info: '#1565c0' };
		return E('span', {
			'style': 'display:inline-block;padding:.1em .6em;border-radius:1em;font-size:90%;font-weight:bold;color:#fff;background:' + (colors[kind] || colors.idle)
		}, text);
	},

	showBusy: function(title, text) {
		ui.showModal(title, [
			E('p', { 'class': 'spinning' }, text || _('Please wait…'))
		]);
	},

	/* Confirmation before a destructive action; resolves true only on the
	 * explicit confirm button (Cancel / closing the dialog = false). */
	confirm: function(title, text, confirmLabel) {
		return new Promise(function(resolve) {
			let done = false;
			const finish = function(v) { if (!done) { done = true; ui.hideModal(); resolve(v); } };
			ui.showModal(title, [
				E('p', {}, text),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': function() { finish(false); } }, _('Cancel')),
					' ',
					E('button', { 'class': 'btn cbi-button-negative', 'click': function() { finish(true); } }, confirmLabel || _('Delete'))
				])
			]);
		});
	},

	/* verdict: 'ok' | 'bad' | 'warn' */
	showResult: function(title, verdict, headline, details, extra) {
		const kind = (verdict === true) ? 'ok' : (verdict === false ? 'bad' : verdict);
		ui.showModal(title, [
			E('p', {}, [ this.badge(kind == 'ok' ? _('PASSED') : (kind == 'warn' ? _('WARNING') : _('FAILED')), kind), ' ', E('strong', {}, headline || '') ]),
			extra || '',
			details ? E('pre', { 'style': 'white-space:pre-wrap;max-height:22em;overflow:auto;font-size:90%' }, details) : '',
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
			])
		]);
	},

	notify: function(text, kind) {
		ui.addNotification(null, E('p', text), kind || 'info');
	},

	/* ---------- saving / service control ---------- */

	/* Save the form and commit easy_vless: the runtime reads only the
	 * committed configuration. Deliberately not LuCI's "apply" (that would
	 * restart the service through ucitrack without the sing-box check). */
	saveAndCommit: function(map) {
		const maps = map ? L.toArray(map) : [];
		let stage = 'form';
		return Promise.all(maps.map(function(m) { return m.save(null, true); })).then(function() {
			stage = 'save';
			return uci.save();
		}).then(function() {
			stage = 'commit';
			return callUciCommit(CONFIG);
		}).catch(function(e) {
			const msg = (e && e.message) ? e.message : String(e);
			if (stage == 'form')
				ui.addNotification(null, E('p', _('The form contains invalid values, nothing was saved: %s').format(msg)), 'error');
			else
				ui.addNotification(null, E('p', _('Saving failed (%s): %s').format(stage == 'commit' ? 'uci commit' : 'uci save', msg)), 'error');
			if (e && typeof(e) == 'object')
				e.ev_notified = true;
			throw e;
		}).then(function() {
			/* uci commit renumbers anonymous sections (cfgXXXXXX, e.g. URL
			 * subscriptions) after a delete: reload the committed config and
			 * re-render the (already saved) maps so row actions use valid ids. */
			uci.unload(CONFIG);
			return Promise.all(maps.map(function(m) {
				return m.load().then(function() { return m.renderContents(); });
			}));
		}).then(function() {
			return ui.changes.init();
		});
	},

	/* Show an unexpected failure of a UI operation (errors already shown by
	 * saveAndCommit are not repeated). Never "catch and ignore". */
	reportError: function(title, e) {
		if (e && e.ev_notified)
			return;
		ui.addNotification(null, E('p', _('%s failed: %s').format(title, (e && e.message) ? e.message : String(e))), 'error');
	},

	/* One service/config operation at a time (Start, Stop, Check, Apply,
	 * Save, tests, updates): a second click while one runs is refused. */
	opRunning: null,

	exclusive: function(title, fn) {
		if (this.opRunning) {
			this.notify(_('"%s" is still running; wait until it has finished.').format(this.opRunning), 'warning');
			return Promise.resolve();
		}
		this.opRunning = title;
		const done = L.bind(function() { this.opRunning = null; }, this);
		return Promise.resolve().then(fn).then(done, L.bind(function(e) {
			done();
			this.reportError(title, e);
		}, this));
	},

	handleSave: function(map) {
		return this.exclusive(_('Save'), L.bind(function() {
			return this.saveAndCommit(map).then(L.bind(function() {
				this.notify(_('Configuration saved. The running service is not changed; use Save & Apply to apply it.'));
			}, this));
		}, this));
	},

	/* Save & Apply (PassWall2 semantics): main switch on -> check + (re)start,
	 * main switch off -> stop. */
	handleApply: function(map) {
		return this.exclusive(_('Save & Apply'), L.bind(function() {
			return this.saveAndCommit(map).then(L.bind(function() {
				if (uci.get(CONFIG, 'global', 'enabled') == '1')
					return this.startFlow().then(L.bind(this.syncSwitch, this, map));
				return this.callStatus().then(L.bind(function(st) {
					if (st.rpc_error)
						return this.showResult(_('Save & Apply'), 'bad', _('Saved, but the service state is unknown'), st.error);
					if (st.running || st.nft_table)
						return this.stopFlow().then(L.bind(this.syncSwitch, this, map));
					this.notify(_('Saved. The main switch is off, Easy VLESS stays stopped.'));
				}, this));
			}, this));
		}, this));
	},

	handleCheck: function(map) {
		return this.exclusive(_('Check config'), L.bind(function() {
			return this.saveAndCommit(map).then(L.bind(function() {
				this.showBusy(_('Check config'), _('Generating the sing-box configuration and running "sing-box check"…'));
				return this.callCheck('');
			}, this)).then(L.bind(function(res) {
				if (res.ok || res.code === 0)
					this.showResult(_('Check config'), 'ok', _('sing-box configuration is valid'), res.output);
				else
					this.showResult(_('Check config'), 'bad', res.rpc_error ? _('Check could not run') : _('sing-box rejected the configuration'), res.output || res.error);
			}, this));
		}, this));
	},

	handleStart: function(map) {
		return this.exclusive(_('Save & Start'), L.bind(function() {
			return this.saveAndCommit(map).then(L.bind(this.startFlow, this))
				.then(L.bind(this.syncSwitch, this, map));
		}, this));
	},

	/* Stop also turns the main switch off (done by the rpcd "stop" method). */
	handleStop: function(map) {
		return this.exclusive(_('Stop'), L.bind(function() {
			return this.stopFlow().then(L.bind(this.syncSwitch, this, map));
		}, this));
	},

	/* start/stop change global.enabled on the router. Show the real value in
	 * the Main switch widget without reloading the form, so other unsaved
	 * edits are kept (the next Save writes the widget value). */
	syncSwitch: function(map) {
		const maps = map ? L.toArray(map) : [];
		return this.callStatus().then(function(st) {
			if (st.rpc_error)
				return;
			maps.forEach(function(m) {
				const res = m.lookupOption ? m.lookupOption('enabled', 'global') : null;
				const opt = res ? res[0] : null;
				const el = opt ? opt.getUIElement('global') : null;
				if (el)
					el.setValue(st.enabled ? '1' : '0');
			});
		});
	},

	/* check -> enable + detached restart -> poll status (health) -> result. */
	startFlow: function() {
		let before;
		this.showBusy(_('Start'), _('Checking the configuration with sing-box…'));
		return this.callStatus().then(L.bind(function(st) {
			before = st || {};
			return safe(callStart());
		}, this)).then(L.bind(function(res) {
			if (res.rpc_error)
				return this.showResult(_('Start'), 'bad', _('Start request failed'), res.output);
			if (!res.ok && res.code !== 0)
				return this.showResult(_('Start'), 'bad', _('Not started: configuration check failed. Network settings were not changed.'), res.output);
			this.showBusy(_('Start'), _('Configuration valid. Starting sing-box, firewall and DNS…'));
			return this.waitFor(function(st, sawBusy, elapsed) {
				if (st.busy)
					return null;
				if (st.running && (!before.running || st.pid != before.pid))
					return true;
				if (sawBusy || elapsed > 12000)
					return false;
				return null;
			}, 45000, res.log_mark).then(L.bind(function(r) {
				this.lastStatus = r.status;
				this.refreshStatus();
				if (r.done) {
					const st = r.status;
					this.showResult(_('Start'), 'ok', _('Running'), null, E('ul', {}, [
						E('li', {}, _('PID: %s').format(st.pid)),
						E('li', {}, _('sing-box: %s').format(st.singbox_version || '?')),
						E('li', {}, _('Firewall: %s').format(st.nft_table ? _('nft table inet easy_vless present') : _('absent'))),
						E('li', {}, _('Memory: %s').format(st.rss_kb ? '%.1f MiB'.format(st.rss_kb / 1024) : '-'))
					]));
				}
				else {
					this.showResult(_('Start'), 'bad', r.timeout ? _('Start did not finish in time') : _('sing-box is not running (the start was rolled back)'), (r.status && r.status.log) || '');
				}
			}, this));
		}, this));
	},

	stopFlow: function() {
		this.showBusy(_('Stop'), _('Stopping Easy VLESS and removing its firewall rules…'));
		return safe(callStop()).then(L.bind(function(res) {
			if (res.rpc_error)
				return this.showResult(_('Stop'), 'bad', _('Stop request failed'), res.output);
			return this.waitFor(function(st, sawBusy, elapsed) {
				if (st.busy)
					return null;
				if (!st.running && (sawBusy || elapsed > 3000))
					return true;
				return elapsed > 20000 ? false : null;
			}, 30000, res.log_mark).then(L.bind(function(r) {
				this.lastStatus = r.status;
				this.refreshStatus();
				if (r.done && !r.status.nft_table)
					this.showResult(_('Stop'), 'ok', _('Stopped. sing-box, nft table, ip rules and DNS changes were removed.'));
				else if (r.done)
					this.showResult(_('Stop'), 'warn', _('Stopped, but the nft table inet easy_vless is still present.'), r.status.log);
				else
					this.showResult(_('Stop'), 'bad', _('Easy VLESS did not stop in time.'), (r.status && r.status.log) || '');
			}, this));
		}, this));
	},

	/* Poll status until cond(status, sawBusy, elapsed) returns true/false. */
	waitFor: function(cond, timeout, logFrom) {
		const t0 = Date.now();
		let sawBusy = false;
		const step = L.bind(function() {
			return sleep(1500).then(L.bind(function() { return this.callStatus(logFrom); }, this)).then(function(st) {
				st = st || {};
				if (st.busy)
					sawBusy = true;
				const elapsed = Date.now() - t0;
				const r = st.rpc_error ? null : cond(st, sawBusy, elapsed);
				if (r === true || r === false)
					return { done: r, status: st };
				if (elapsed > timeout)
					return { done: false, timeout: true, status: st };
				return step();
			});
		}, this);
		return step();
	},

	/* Apply a changed target right away if the service is running. */
	applyIfRunning: function(map) {
		return this.saveAndCommit(map).then(L.bind(function() {
			return this.callStatus();
		}, this)).then(L.bind(function(st) {
			if (st.running)
				return this.startFlow();
			this.notify(_('Saved. Easy VLESS is stopped; the change applies on the next start.'));
		}, this)).catch(L.bind(this.reportError, this, _('Apply')));
	},

	/* ---------- status ---------- */

	lastStatus: {},

	card: function(title, value, sub) {
		return E('div', { 'style': 'border:1px solid rgba(128,128,128,.35);border-radius:.5em;padding:.6em .8em;min-width:0' }, [
			E('div', { 'style': 'font-size:85%;opacity:.75' }, title),
			E('div', { 'style': 'font-size:115%;font-weight:bold;margin-top:.2em;overflow:hidden;text-overflow:ellipsis' }, value),
			sub ? E('div', { 'style': 'font-size:85%;opacity:.75;margin-top:.2em;overflow:hidden;text-overflow:ellipsis' }, sub) : ''
		]);
	},

	activeText: function(node) {
		if (!node)
			return _('none selected');
		if (node == ROUTER)
			return _('Main Router');
		return uci.get(CONFIG, node, 'remarks') || node;
	},

	renderStatus: function(st, compact) {
		st = st || {};
		const running = !!st.running;
		const node = st.node || uci.get(CONFIG, 'global', 'node');
		let core;
		if (st.rpc_error)
			core = this.badge(_('unknown'), 'warn');
		else if (st.busy)
			core = this.badge(_('Starting / stopping…'), 'info');
		else if (running)
			core = this.badge(_('Running'), 'ok');
		else
			core = this.badge(_('Stopped'), st.enabled ? 'bad' : 'idle');

		/* Other pages: one compact status line (service lifecycle is on Main). */
		if (compact) {
			const item = function(label, value) {
				return E('span', { 'style': 'margin-right:1.5em;white-space:nowrap' }, [ E('span', { 'style': 'opacity:.7' }, label + ': '), value ]);
			};
			return E('div', { 'style': 'display:flex;flex-wrap:wrap;align-items:center;padding:.4em .7em;border:1px solid rgba(128,128,128,.35);border-radius:.4em' }, [
				item(_('Core'), E('span', {}, [ core, running ? ' ' + _('PID %s').format(st.pid) : '' ])),
				item(_('Main switch'), st.enabled ? _('Enabled') : _('Disabled')),
				item(_('Active'), E('strong', {}, this.activeText(node) + (node == ROUTER ? ' → ' + this.label(uci.get(CONFIG, ROUTER, 'default_node') || '_direct') : ''))),
				st.rpc_error ? E('span', { 'style': 'color:#c62828' }, _('Status unavailable: %s').format(st.error)) : ''
			]);
		}

		const cards = [
			this.card(_('Core'), core, running ? _('PID %s').format(st.pid) : (st.enabled && !st.busy ? _('main switch is on, but not running') : '')),
			this.card(_('Main switch'), st.enabled ? _('Enabled') : _('Disabled'), st.enabled ? _('starts on boot') : ''),
			this.card(_('Active'), this.activeText(node), node == ROUTER ? _('Default: %s').format(this.label(uci.get(CONFIG, ROUTER, 'default_node') || '_direct')) : '')
		];
		if (!compact) {
			cards.push(
				this.card(_('sing-box'), st.singbox_version || _('not found'),
					st.singbox_version ? (st.singbox_backend ? '' : _('easy-vless-sing-box missing')) : _('requires sing-box >= %s').format(st.singbox_min_version || '1.12.0')),
				this.card(_('Memory (RSS)'), running && st.rss_kb ? '%.1f MiB'.format(st.rss_kb / 1024) : '-',
					running && st.rss_peak_kb ? _('peak %.1f MiB').format(st.rss_peak_kb / 1024) : ''),
				this.card(_('Firewall'), st.nft_table ? _('present') : _('absent'), 'nft inet easy_vless'),
				this.card(_('Routing mode'), st.routing_mode || 'singbox', '')
			);
		}
		if (st.rpc_error)
			cards.push(E('div', { 'class': 'alert-message warning', 'style': 'grid-column:1/-1' }, _('Status unavailable: %s').format(st.error)));

		return E('div', {}, [
			E('div', { 'style': 'display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:.6em' }, cards),
			compact ? '' : E('details', { 'style': 'margin-top:.6em' }, [
				E('summary', {}, _('Recent log')),
				E('pre', { 'style': 'white-space:pre-wrap;max-height:20em;overflow:auto;font-size:90%' }, st.log || _('(empty)'))
			])
		]);
	},

	statusBoxes: [],

	refreshStatus: function() {
		return this.callStatus().then(L.bind(function(st) {
			this.lastStatus = st;
			document.querySelectorAll('[data-ev-status]').forEach(L.bind(function(box) {
				dom.content(box, this.renderStatus(st, box.getAttribute('data-ev-status') == 'compact'));
			}, this));
			return st;
		}, this));
	},

	/* Status block; service controls (Save & Start / Stop / Check config)
	 * only where controls=true (Main). Other pages show status only. */
	renderHeader: function(map, st, extraButtons, compact, controls) {
		this.lastStatus = st || {};
		let buttons = [];
		if (controls)
			buttons = [
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, 'handleStart', map) }, _('Save & Start')),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-reset', 'click': ui.createHandlerFn(this, 'handleStop', map) }, _('Stop')),
				' ',
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleCheck', map) }, _('Check config'))
			];
		buttons = buttons.concat(extraButtons || []);

		return E('div', { 'class': 'cbi-section' }, [
			E('div', { 'data-ev-status': compact ? 'compact' : 'full' }, this.renderStatus(this.lastStatus, compact)),
			buttons.length ? E('div', { 'style': 'margin:.8em 0 0' }, buttons) : ''
		]);
	},

	/* Modal "Save" of a GridSection (Add/Edit) commits the configuration
	 * right away: the node/group/subscription/rule is saved, no second
	 * footer Save needed. The running service is not restarted. */
	commitOnModalSave: function(s, what) {
		const Grid = s.constructor;
		const self = this;
		s.handleModalSave = function(modalMap, ev_) {
			const map = this.map;
			return Grid.prototype.handleModalSave.apply(this, arguments).then(function() {
				/* the modal stays open when validation failed */
				if (document.body.classList.contains('modal-overlay-active'))
					return;
				return self.exclusive(_('Save'), function() {
					return self.saveAndCommit(map).then(function() {
						self.notify(_('%s saved.').format(what) + ' ' + _('Changes of a running service apply with Save & Apply on Main.'));
					});
				});
			});
		};
	},

	/* Shared page CSS (one look on every Easy VLESS page): dense tables and
	 * natural-width row buttons (the theme stretches them to 4em flex
	 * cells, which clips labels when there are many actions). */
	pageStyle: function() {
		return E('style', {}, [
			'.ev-page .cbi-section-table .td, .ev-page .cbi-section-table .th { padding: .35em .45em; }',
			'.ev-page .td.cbi-section-actions { width: 1%; white-space: nowrap; }',
			'.ev-page .td.cbi-section-actions > * { display: flex; flex-wrap: nowrap; justify-content: flex-end; }',
			'.ev-page .td.cbi-section-actions > * > * { flex: 0 0 auto !important; }',
			'.ev-page .td.cbi-section-actions .cbi-button { padding: 0 .45em; margin: .05em; line-height: 1.9em; min-width: 0; }',
			'.ev-page h2 { margin-bottom: .3em; }',
			'.ev-page .cbi-section > h3 { margin-top: .8em; }'
		].join('\n'));
	},

	/* Small action button used in tables. */
	smallButton: function(label, title, cls, handler) {
		return E('button', {
			'class': 'btn cbi-button ' + (cls || ''),
			'style': 'padding:0 .45em;margin:.05em;min-width:0;line-height:1.9em',
			'title': title || '',
			'click': handler
		}, label);
	},

	/* GridSection with no rows: drop the column titles and show a short
	 * one-line placeholder instead of a large empty table. */
	compactWhenEmpty: function(s, text) {
		const Grid = s.constructor;
		s.renderSectionPlaceholder = function() {
			return E('em', { 'style': 'opacity:.7' }, text || _('None yet.'));
		};
		s.renderContents = function(cfgsections, nodes) {
			const el = Grid.prototype.renderContents.apply(this, arguments);
			if (el && el.querySelectorAll && !cfgsections.length)
				el.querySelectorAll('.cbi-section-table-titles, .cbi-section-table-descr').forEach(function(n) { n.remove(); });
			return el;
		};
	},

	/* ---------- Server Test ---------- */

	testResults: {},

	testText: function(r) {
		if (!r)
			return '-';
		if (r.pending)
			return E('em', {}, _('testing…'));
		if (r.ok)
			return E('span', { 'title': '%s → HTTP %s'.format(r.url || SERVER_TEST_URL, r.http_code || '') },
				[ this.badge(_('PASS'), 'ok'), ' ', _('%d ms').format(r.delay), E('br'), E('small', { 'style': 'opacity:.7' }, 'HTTP ' + (r.http_code || '')) ]);
		const err = r.error || _('failed');
		return E('span', { 'title': err }, [ this.badge(_('FAIL'), 'bad'), E('br'),
			E('small', {}, err.length > 60 ? err.substr(0, 57) + '…' : err) ]);
	},

	/* Real per-server test: temporary sing-box instance with the server's
	 * VLESS outbound + HTTPS request to https://www.gstatic.com/generate_204. */
	serverTest: function(sid) {
		this.testResults[sid] = { pending: true, time: Date.now() };
		return this.callUrltestNode(sid).then(L.bind(function(res) {
			if (res.rpc_error)
				res = { ok: false, error: res.error };
			res.time = Date.now();
			this.testResults[sid] = res;
			return res;
		}, this));
	},

	/* Per-node URL Test: same temporary-instance mechanism as the Server
	 * Test, but against the URL Test default https://x.com (any HTTP answer
	 * counts, like sing-box's urltest). */
	urlTestResults: {},

	nodeUrlTest: function(sid) {
		this.urlTestResults[sid] = { pending: true };
		return this.callUrltestNode(sid, URL_TEST_URL).then(L.bind(function(res) {
			if (res.rpc_error)
				res = { ok: false, error: res.error };
			res.time = Date.now();
			this.urlTestResults[sid] = res;
			return res;
		}, this));
	},

	/* ---------- VLESS URL export ---------- */

	/*
	 * Build a standard vless:// URL from the saved UCI values (UCI stays the
	 * only source of truth). Parameter names follow PassWall2's share-link
	 * generator and match subscribe.lua's importer, so export -> import
	 * round-trips. Settings that a VLESS URL cannot carry are reported.
	 */
	buildVlessUrl: function(sid) {
		const g = function(k) { return uci.get(CONFIG, sid, k); };
		const warnings = [];

		if (g('protocol') != 'vless')
			return { url: null, warnings: [ _('Only VLESS servers can be exported.') ] };

		let host = g('address') || '';
		if (host.indexOf(':') > -1 && host.charAt(0) != '[')
			host = '[' + host + ']';

		const params = [];
		const add = function(k, v) {
			if (v != null && v !== '')
				params.push(k + '=' + encodeURIComponent(v));
		};
		const first = function(v) { return Array.isArray(v) ? v[0] : v; };

		let transport = g('transport') || 'tcp';
		let type = transport;

		switch (transport) {
		case 'raw':
		case 'tcp':
			type = 'tcp';
			if (g('tcp_guise') == 'http') {
				add('headerType', 'http');
				add('host', first(g('tcp_guise_http_host')));
				add('path', first(g('tcp_guise_http_path')));
			}
			break;
		case 'ws': {
			let path = g('ws_path') || '';
			if (g('ws_enableEarlyData') == '1' && g('ws_maxEarlyData'))
				path += (path.indexOf('?') > -1 ? '&' : '?') + 'ed=' + g('ws_maxEarlyData');
			add('host', g('ws_host'));
			add('path', path);
			break;
		}
		case 'grpc':
			add('serviceName', g('grpc_serviceName'));
			if (g('grpc_mode') && g('grpc_mode') != 'gun')
				add('mode', g('grpc_mode'));
			break;
		case 'httpupgrade':
			add('host', g('httpupgrade_host'));
			add('path', g('httpupgrade_path'));
			break;
		case 'http':
			add('host', first(g('http_host')));
			add('path', g('http_path'));
			break;
		default:
			warnings.push(_('Transport "%s" has no standard VLESS URL form.').format(transport));
		}

		add('type', type);
		add('encryption', g('encryption') || 'none');

		if (g('tls') == '1') {
			const reality = g('reality') == '1';
			add('security', reality ? 'reality' : 'tls');
			add('sni', g('tls_serverName'));
			if (reality || g('utls') == '1')
				add('fp', g('fingerprint') || 'chrome');
			if (g('alpn') && g('alpn') != 'default')
				add('alpn', g('alpn'));
			if (reality) {
				add('pbk', g('reality_publicKey'));
				add('sid', g('reality_shortId'));
				add('spx', g('reality_spiderX'));
			}
			else if (g('tls_allowInsecure') == '1') {
				add('allowInsecure', '1');
			}
			if (g('ech') == '1' && g('ech_config'))
				add('ech', g('ech_config'));
			add('pcs', g('tls_pinSHA256'));
			add('flow', g('flow'));
		}
		else if (g('flow')) {
			warnings.push(_('Flow "%s" requires TLS/Reality and was not exported.').format(g('flow')));
		}

		if (g('mux') == '1')
			warnings.push(_('Multiplex (mux) settings are not part of a VLESS URL.'));
		if (g('chain_proxy') && g('chain_proxy') != '0')
			warnings.push(_('Proxy chain settings are not part of a VLESS URL.'));
		if (g('domain_resolver') || g('domain_strategy'))
			warnings.push(_('Server domain resolver/strategy settings are not part of a VLESS URL.'));
		if (g('tls_certificate') == '1')
			warnings.push(_('A custom trusted certificate is not part of a VLESS URL.'));

		const url = 'vless://' + encodeURIComponent(g('uuid') || '') + '@' + host + ':' + (g('port') || '') +
			'?' + params.join('&') + '#' + encodeURIComponent(g('remarks') || '');

		return { url: url, warnings: warnings };
	},

	copyText: function(text) {
		if (navigator.clipboard && window.isSecureContext)
			return navigator.clipboard.writeText(text).then(function() { return true; }, function() { return false; });

		/* LuCI is usually served over plain http: use a temporary textarea. */
		const ta = E('textarea', { 'style': 'position:fixed;top:-1000px' }, text);
		document.body.appendChild(ta);
		ta.select();
		let ok = false;
		try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
		document.body.removeChild(ta);
		return Promise.resolve(ok);
	},

	/* URL modal: URL + Copy + QR code (QR needs the optional luci-lib-uqr). */
	showVlessUrl: function(sid) {
		const r = this.buildVlessUrl(sid);
		const pending = (ui.changes && ui.changes.changes) ? L.toArray(ui.changes.changes[CONFIG]) : [];
		const staged = pending.some(function(c) { return c[1] == sid; });
		const field = E('textarea', { 'class': 'cbi-input-textarea', 'style': 'width:100%', 'rows': 4, 'readonly': 'readonly' }, r.url || '');
		const note = E('span', { 'style': 'margin-right:1em' });
		const qrBox = E('div', { 'style': 'text-align:center;margin:.5em 0' });

		ui.showModal(_('VLESS URL') + ' » ' + (uci.get(CONFIG, sid, 'remarks') || sid), [
			field,
			r.warnings.length ? E('div', { 'class': 'alert-message warning' }, [
				E('p', {}, _('Not included in the URL:')),
				E('ul', {}, r.warnings.map(function(w) { return E('li', {}, w); }))
			]) : '',
			qrBox,
			E('p', { 'class': 'cbi-value-description' }, _('Built from the settings saved in this browser session (UCI); edits still open in a form are not included.')),
			staged ? E('div', { 'class': 'alert-message warning' }, _('This server has saved changes that are not committed yet (press Save): the running service still uses the previous values.')) : '',
			E('div', { 'class': 'right' }, [
				note,
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close')),
				' ',
				r.url ? E('button', {
					'class': 'btn cbi-button-action',
					'click': L.bind(function() {
						field.select();
						return this.copyText(r.url).then(function(ok) {
							note.textContent = ok ? _('Copied.') : _('Copy failed - select the text and copy manually.');
						});
					}, this)
				}, _('Copy')) : ''
			])
		]);
		field.select();

		if (r.url) {
			L.require('uqr').then(function(uqr) {
				qrBox.innerHTML = uqr.renderSVG(r.url, { pixelSize: 3, whiteColor: '#fff', blackColor: '#000' });
				const svg = qrBox.querySelector('svg');
				if (svg)
					svg.setAttribute('style', 'max-width:260px;height:auto;background:#fff;padding:6px');
			}).catch(function() {
				qrBox.appendChild(E('small', { 'style': 'opacity:.7' }, _('QR support unavailable. Install luci-lib-uqr to enable QR.')));
			});
		}
	}
});
