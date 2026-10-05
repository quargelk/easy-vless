'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require easy_vless.common as ev';

/*
 * Easy VLESS - First Run Wizard (0.6.0, 2.0 in 0.8.0): onboarding only, no
 * second configuration system. Every step uses what Main, Node List and Rule
 * Manage already use:
 *   Link         a vless:// or trojan:// link -> rpcd "import" (subscribe.lua
 *                parser, same as Node List -> Import URL); an
 *                http(s):// link -> a normal URL Subscription (config
 *                subscribe_list) updated with rpcd "subscribe" (subscribe.lua,
 *                same as Node List -> Update); or a server already in Node List
 *   Server       one of the imported / subscribed / existing servers
 *   Test         Server Test, then URL Test: the test queue of the router
 *                (rpcd "test": temporary sing-box instance with the server's
 *                VLESS outbound, HTTPS to generate_204 and to https://x.com)
 *   Routing      the prepared rules of the resource manifest (Rule Manage ->
 *                Add prepared rule, ev.applyTemplate) and the Main Router
 *                targets (main_router.<rule id>, main_router.default_node)
 *   Apply        uci commit, rpcd "check" (sing-box check) and "start"
 *                (the path of Main -> Save & Start); rpcd "wizard" keeps a
 *                copy of the committed configuration and puts it back when
 *                a step fails, so nothing stays half-applied
 * Servers and subscriptions the wizard adds are ordinary Node List entries.
 * State: the step and the entered values live in this browser tab
 * (sessionStorage) until the wizard ends; the router only stores
 * easy_vless.global.wizard_completed=1 after a successful Apply.
 */

/* strings are text, not HTML (see ev.E in common.js) */
const E = ev.E;
const CONFIG = ev.CONFIG;
const ROUTER = ev.ROUTER;
const STORE = 'easy_vless.wizard';

const STEP_WELCOME = 0, STEP_LINK = 1, STEP_SERVER = 2, STEP_TEST = 3, STEP_ROUTING = 4, STEP_REVIEW = 5, STEP_APPLY = 6, STEP_DONE = 7;
const STEPS = [ _('Welcome'), _('Link'), _('Server'), _('Test'), _('Routing'), _('Review'), _('Apply'), _('Done') ];

let TEMPLATES = [];
let RESOURCES_ERROR = null;

function readState() {
	try {
		const v = JSON.parse(window.sessionStorage.getItem(STORE) || 'null');
		return (v && typeof(v) == 'object') ? v : null;
	}
	catch (e) {
		return null;
	}
}

function writeState(st) {
	try { window.sessionStorage.setItem(STORE, JSON.stringify(st)); } catch (e) {}
}

function clearState() {
	try { window.sessionStorage.removeItem(STORE); } catch (e) {}
}

/* One trojan:// link (1.1): password, address and port must be there. */
function trojanLinkError(v) {
	const p = v.match(/^trojan:\/\/([^\/?#]+)@(\[[0-9A-Fa-f:.]+\]|[^:@\/?#\[\]]+):(\d+)(?:[\/?#]|$)/i);
	if (!p)
		return _('The link is incomplete: expected trojan://password@address:port?parameters#name');
	const port = +p[3];
	if (port < 1 || port > 65535)
		return _('The port in the link must be between 1 and 65535.');
	return null;
}

/* One vless:// or trojan:// link, checked before it is sent to the router: a
 * clear reason instead of "0 imported". Returns an error text or null. */
function linkError(v) {
	v = (v || '').trim();
	if (/^trojan:\/\//i.test(v))
		return trojanLinkError(v);
	const p = v.match(/^vless:\/\/([^@\/?#]+)@(\[[0-9A-Fa-f:.]+\]|[^:\/?#\[\]]+):(\d+)(?:[\/?#]|$)/i);
	if (!p)
		return _('The link is incomplete: expected vless://UUID@address:port?parameters#name');
	let uuid = p[1];
	try { uuid = decodeURIComponent(uuid); } catch (e) {}
	if (!/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(uuid))
		return _('The user ID in the link is not a UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).');
	const port = +p[3];
	if (port < 1 || port > 65535)
		return _('The port in the link must be between 1 and 65535.');
	return null;
}

/* What was pasted: { kind: 'vless' | 'trojan' | 'sub' | null, error }. A
 * vless:// or trojan:// link is one server; an http(s):// link is taken for a
 * subscription, which is only confirmed when the router downloads it and
 * finds servers. */
function detectInput(v) {
	v = (v || '').trim();
	if (!v)
		return { kind: null, error: _('Paste the vless:// or trojan:// link of your server or the subscription link of your provider.') };
	const parts = v.split(/\s+/).filter(function(x) { return x; });
	if (parts.length > 1)
		return { kind: null, error: _('Paste exactly one link. More servers can be added later in Node List.') };
	const m = v.match(/^([A-Za-z][A-Za-z0-9+.-]*):\/\//);
	if (!m)
		return { kind: null, error: _('This is not a link: a server link starts with vless:// or trojan://, a subscription link with https://') };
	const scheme = m[1].toLowerCase();
	if (scheme == 'vless' || scheme == 'trojan') {
		const err = linkError(v);
		return { kind: scheme, error: err };
	}
	if (scheme == 'http' || scheme == 'https') {
		if (!/^https?:\/\/[^\s\/?#@]+(:\d+)?([\/?#]\S*)?$/i.test(v))
			return { kind: 'sub', error: _('The subscription link is incomplete: expected https://address/path') };
		return { kind: 'sub', error: null };
	}
	return { kind: null, error: _('"%s://" links are not supported: Easy VLESS works with VLESS and Trojan servers (vless://, trojan://).').format(scheme) };
}

/* Why subscribe.lua did not import a link: its own log lines. */
function importReason(res) {
	const lines = ((res.log || '') + '\n' + (res.output || '')).split(/\n/).map(function(l) {
		return l.replace(/^\S+ \S+ /, '').replace(/^\[[^\]]*\]\s*/, '').trim();
	}).filter(function(l) {
		return /skip|discard|parsing error|not support|invalid|error/i.test(l);
	});
	return lines.length ? lines.join('\n') : '';
}

function securityText(sid) {
	if (uci.get(CONFIG, sid, 'tls') != '1')
		return _('none');
	return uci.get(CONFIG, sid, 'reality') == '1' ? 'Reality' : 'TLS';
}

function transportText(sid) {
	const v = uci.get(CONFIG, sid, 'transport') || 'tcp';
	return { raw: 'TCP', tcp: 'TCP', ws: 'WebSocket', grpc: 'gRPC', httpupgrade: 'HTTPUpgrade' }[v] || v;
}

function kv(rows) {
	return E('table', { 'class': 'table ev-wiz-kv' }, rows.filter(function(r) { return r; }).map(function(r) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'style': 'width:35%;opacity:.8' }, r[0]),
			E('td', { 'class': 'td' }, r[1])
		]);
	}));
}

function serverRows(sid) {
	const g = function(k) { return uci.get(CONFIG, sid, k); };
	return [
		[ _('Name'), E('strong', {}, g('remarks') || sid) ],
		[ _('Protocol'), ev.protocolName(g('protocol')) ],
		[ _('Address'), (g('address') || '-') + ':' + (g('port') || '-') ],
		[ _('Transport'), transportText(sid) ],
		[ _('Security'), securityText(sid) ],
		g('tls') == '1' && g('tls_serverName') ? [ 'SNI', g('tls_serverName') ] : null,
		g('flow') ? [ 'Flow', g('flow') ] : null,
		(g('add_mode') == '2' && g('group')) ? [ _('Source'), _('Subscription: %s').format(g('group')) ] : null
	];
}

function testLine(r, url) {
	if (!r)
		return E('em', {}, _('not tested yet'));
	if (r.pending)
		return E('span', { 'style': 'white-space:nowrap' }, [ E('span', { 'class': 'spinning', 'style': 'display:inline-block;width:1em' }, ' '), ' ', _('Testing…') ]);
	if (r.skipped)
		return E('em', {}, _('not run: the Server Test failed'));
	if (r.ok)
		return E('span', {}, [ ev.badge(_('PASS'), 'ok'), ' ', _('%d ms').format(r.delay), ' ',
			E('small', { 'style': 'opacity:.7' }, 'HTTP ' + (r.http_code || '') + ' · ' + url) ]);
	return E('span', {}, [ ev.badge(_('FAIL'), 'bad'), ' ', E('span', { 'class': 'ev-wiz-reason' }, ev.testError(r)),
		E('br'), E('small', { 'style': 'opacity:.7' }, url) ]);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(CONFIG),
			ev.callStatus(),
			ev.callWizardState(),
			ev.callResources(),
			ev.refreshTests(),
			ev.refreshSubscriptions()
		]);
	},

	/* ---------- state ---------- */

	st: null,
	busy: false,

	save: function() {
		writeState(this.st);
	},

	defaults: function() {
		return {
			step: STEP_WELCOME,
			mode: ev.servers().length ? 'existing' : 'paste',
			url: '',
			serverId: null,
			importedId: null,       /* server imported from a vless:// link */
			importedUrl: null,
			subId: null,            /* subscription loaded in this run */
			subUrl: null,
			subCreated: false,      /* ... and added by the wizard */
			subHwid: false,
			subUa: 'auto',
			source: null,           /* 'vless' | 'sub' | 'existing' */
			candidates: [],
			routing: null,
			tests: {},
			apply: null,
			result: null
		};
	},

	serverOk: function(sid) {
		return !!sid && ev.isServer(sid);
	},

	subOk: function(id) {
		return !!id && uci.get(CONFIG, id) != null && uci.get(CONFIG, id)['.type'] == 'subscribe_list';
	},

	reloadUci: function() {
		uci.unload(CONFIG);
		return uci.load(CONFIG);
	},

	/* Servers offered on the Server step. */
	candidates: function() {
		const st = this.st;
		if (st.source == 'existing')
			return ev.servers().map(function(s) { return s['.name']; });
		if (st.source == 'sub' && this.subOk(st.subId)) {
			const remark = (uci.get(CONFIG, st.subId, 'remark') || '').toLowerCase();
			return ev.servers().filter(function(s) { return s.add_mode == '2' && (s.group || '').toLowerCase() == remark; })
				.map(function(s) { return s['.name']; });
		}
		return L.toArray(st.candidates).filter(L.bind(this.serverOk, this));
	},

	/* ---------- routing plan (shown in Review, written by Apply) ---------- */

	routingChoices: function() {
		const list = [];
		list.push('basic');
		list.push('all');
		if (this.wstate.node_ok)
			list.push('keep');
		return list;
	},

	defaultRouting: function() {
		return this.wstate.node_ok ? 'keep' : 'basic';
	},

	/* ops: [{ kind: 'rule', t, id, before, target } | { kind: 'default' |
	 * 'node', before, after }] - the only changes Apply makes to routing. */
	routingPlan: function(choice, server) {
		const ops = [];
		const node = uci.get(CONFIG, 'global', 'node') || '';
		if (choice == 'all') {
			ops.push({ kind: 'node', before: node, after: server });
		}
		else if (choice == 'basic') {
			TEMPLATES.forEach(function(t) {
				const ex = ev.rules().filter(function(r) { return (r.remarks || '') == t.remarks; })[0];
				const target = (t.target == '@active') ? server : (t.target || '_direct');
				ops.push({ kind: 'rule', t: t, id: ex ? ex['.name'] : null,
					before: ex ? (uci.get(CONFIG, ROUTER, ex['.name']) || '') : null, target: target });
			});
			ops.push({ kind: 'default', before: uci.get(CONFIG, ROUTER) ? (uci.get(CONFIG, ROUTER, 'default_node') || '_direct') : null, after: server });
			ops.push({ kind: 'node', before: node, after: ROUTER });
		}
		return ops;
	},

	applyPlan: function(ops, server) {
		ops.forEach(function(op) {
			if (op.kind == 'rule')
				ev.applyTemplate(op.t, op.target, server);
			else if (op.kind == 'default') {
				ev.ensureRouter();
				uci.set(CONFIG, ROUTER, 'default_node', op.after);
			}
			else if (op.kind == 'node')
				uci.set(CONFIG, 'global', 'node', op.after);
		});
	},

	/* Rows "entry -> target" of the routing as it will be after Apply. */
	routingRows: function(choice, server) {
		const rows = [];
		const target = function(t) { return t ? ev.label(t) : E('em', {}, _('Not used')); };
		if (choice == 'keep') {
			const node = uci.get(CONFIG, 'global', 'node');
			if (node == ROUTER) {
				ev.rules().forEach(function(r) {
					const t = uci.get(CONFIG, ROUTER, r['.name']);
					if (t)
						rows.push([ r.remarks || r['.name'], target(t == '_default' ? (uci.get(CONFIG, ROUTER, 'default_node') || '_direct') : t) ]);
				});
				rows.push([ _('Default'), target(uci.get(CONFIG, ROUTER, 'default_node') || '_direct') ]);
			}
			else
				rows.push([ _('All traffic'), target(node) ]);
			return rows;
		}
		if (choice == 'all')
			return [ [ _('All traffic'), target(server) ] ];
		const ops = this.routingPlan(choice, server);
		ops.forEach(function(op) {
			if (op.kind == 'rule') {
				let note = '';
				if (op.id == null)
					note = _('new rule');
				else if (op.before && op.before != op.target)
					note = _('was: %s').format(ev.label(op.before));
				rows.push([ op.t.remarks, E('span', {}, [ target(op.target), note ? E('small', { 'style': 'opacity:.7' }, ' (' + note + ')') : '' ]) ]);
			}
		});
		/* other existing rules keep their targets */
		const names = TEMPLATES.map(function(t) { return t.remarks; });
		ev.rules().forEach(function(r) {
			const t = uci.get(CONFIG, ROUTER, r['.name']);
			if (t && names.indexOf(r.remarks || '') < 0)
				rows.push([ r.remarks || r['.name'], E('span', {}, [ target(t), E('small', { 'style': 'opacity:.7' }, ' (' + _('unchanged') + ')') ]) ]);
		});
		const def = ops.filter(function(op) { return op.kind == 'default'; })[0];
		rows.push([ _('Default'), E('span', {}, [ target(server),
			(def && def.before && def.before != '_direct' && def.before != server) ? E('small', { 'style': 'opacity:.7' }, ' (' + _('was: %s').format(ev.label(def.before)) + ')') : '' ]) ]);
		return rows;
	},

	/* ---------- rendering ---------- */

	style: function() {
		return E('style', {}, [
			'.ev-wiz { max-width: 52em; }',
			'.ev-wiz-steps { display: flex; flex-wrap: wrap; gap: .3em; list-style: none; margin: .4em 0 1em; padding: 0; }',
			'.ev-wiz-steps li { padding: .2em .6em; border-radius: 1em; border: 1px solid rgba(128,128,128,.35); font-size: 90%; opacity: .65; }',
			'.ev-wiz-steps li.done { opacity: .9; }',
			'.ev-wiz-steps li.current { opacity: 1; font-weight: bold; border-color: #1565c0; background: rgba(21,101,192,.12); }',
			'.ev-wiz-body { min-height: 12em; }',
			'.ev-wiz-body p { margin: .4em 0; }',
			'.ev-wiz-nav { display: flex; flex-wrap: wrap; gap: .5em; justify-content: space-between; align-items: center; margin-top: 1.2em; padding-top: .8em; border-top: 1px solid rgba(128,128,128,.35); }',
			'.ev-wiz-nav > div { display: flex; flex-wrap: wrap; gap: .5em; }',
			'.ev-wiz-choice { display: block; padding: .6em .8em; margin: .4em 0; border: 1px solid rgba(128,128,128,.35); border-radius: .4em; cursor: pointer; }',
			'.ev-wiz-choice.selected { border-color: #1565c0; background: rgba(21,101,192,.08); }',
			'.ev-wiz-choice input { margin-right: .5em; }',
			'.ev-wiz-error { color: #c62828; font-weight: bold; white-space: pre-wrap; }',
			'.ev-wiz-detect { margin: .4em 0; min-height: 1.4em; }',
			'.ev-wiz-reason { white-space: pre-wrap; }',
			'.ev-wiz-kv { width: 100%; table-layout: fixed; }',
			'.ev-wiz-kv .td { padding: .25em .45em; overflow-wrap: anywhere; word-break: break-word; }',
			'.ev-wiz-descr { margin: .3em 0 0 1.6em; font-size: 95%; }',
			'.ev-wiz pre, .ev-wiz-error, .ev-wiz-reason { overflow-wrap: anywhere; }',
			'.ev-wiz-check li { margin: .25em 0; list-style: none; }',
			'.ev-wiz textarea { width: 100%; box-sizing: border-box; }',
			'.ev-wiz-nodes { width: 100%; border-collapse: collapse; }',
			'.ev-wiz-nodes td { padding: .35em .45em; border-top: 1px solid rgba(128,128,128,.25); vertical-align: top; overflow-wrap: anywhere; }',
			'.ev-wiz-nodes tr.selected td { background: rgba(21,101,192,.08); }',
			'.ev-wiz-nodes tr { cursor: pointer; }',
			'.ev-wiz-opts { margin: .5em 0; }',
			'.ev-wiz-opts label { display: block; margin: .3em 0; }',
			'@media (max-width: 600px) { .ev-wiz-steps li:not(.current) { display: none; } .ev-wiz-nav button { flex: 1 1 auto; } .ev-wiz-nodes .ev-wiz-hide-sm { display: none; } }'
		].join('\n'));
	},

	render: function(data) {
		this.status = data[1] || {};
		this.wstate = data[2] || {};
		const res = data[3] || {};
		TEMPLATES = res.ok ? L.toArray(res.rule_templates) : [];
		RESOURCES_ERROR = res.ok ? null : (res.error || _('unknown error'));

		this.st = Object.assign(this.defaults(), readState() || {});
		const st = this.st;
		/* a server / subscription that no longer exists (deleted in Node List meanwhile) */
		if (st.serverId && !this.serverOk(st.serverId))
			st.serverId = null;
		if (st.importedId && !this.serverOk(st.importedId))
			st.importedId = st.importedUrl = null;
		if (st.subId && !this.subOk(st.subId))
			st.subId = st.subUrl = null;
		if (st.step >= STEP_SERVER && st.step < STEP_DONE && !this.candidates().length)
			st.step = STEP_LINK;
		if (st.step > STEP_SERVER && st.step < STEP_DONE && !st.serverId)
			st.step = STEP_SERVER;
		/* page reloaded while Apply ran: Review again (a leftover copy of the
		 * configuration is offered for restore on that page) */
		if (st.step == STEP_APPLY)
			st.step = STEP_REVIEW;
		if (st.step == STEP_DONE && !st.result)
			st.step = STEP_WELCOME;
		if (!st.routing || this.routingChoices().indexOf(st.routing) < 0)
			st.routing = this.defaultRouting();
		this.save();

		this.progressEl = E('ol', { 'class': 'ev-wiz-steps' });
		this.bodyEl = E('div', { 'class': 'ev-wiz-body' });
		this.navEl = E('div', { 'class': 'ev-wiz-nav' });
		this.redraw();
		/* test results of the router (Server step: latency of the servers) */
		ev.onTestUpdate(L.bind(function() {
			if (this.st.step == STEP_SERVER)
				this.refreshNodeTests();
		}, this));

		return E('div', { 'class': 'ev-page ev-wiz', 'id': 'ev-wizard' }, [
			ev.pageStyle(),
			this.style(),
			E('h2', {}, _('Easy VLESS setup')),
			this.progressEl,
			this.bodyEl,
			this.navEl
		]);
	},

	redraw: function() {
		const st = this.st;
		dom.content(this.progressEl, STEPS.map(function(name, i) {
			return E('li', { 'class': i == st.step ? 'current' : (i < st.step ? 'done' : ''), 'data-step': i },
				(i == st.step ? _('Step %d of %d').format(i + 1, STEPS.length) + ': ' : (i < st.step ? '✓ ' : '')) + name);
		}));
		const fn = [ 'renderWelcome', 'renderLink', 'renderServer', 'renderTest', 'renderRouting', 'renderReview', 'renderApply', 'renderDone' ][st.step];
		const r = this[fn]();
		dom.content(this.bodyEl, r.body);
		dom.content(this.navEl, [ E('div', {}, r.left || []), E('div', {}, r.right || []) ]);
		this.bodyEl.setAttribute('data-step', String(st.step));
	},

	button: function(label, cls, handler, id, disabled) {
		return E('button', {
			'class': 'btn cbi-button ' + (cls || ''),
			'id': id || null,
			'disabled': (disabled || this.busy) ? '' : null,
			'click': ui.createHandlerFn(this, handler)
		}, label);
	},

	cancelButton: function() {
		return this.button(_('Cancel'), 'cbi-button-reset', 'handleCancel', 'ev-wiz-cancel');
	},

	backButton: function() {
		return this.button(_('Back'), '', 'handleBack', 'ev-wiz-back');
	},

	nextButton: function(label, handler, disabled) {
		return this.button(label || _('Next'), 'cbi-button-action', handler || 'handleNext', 'ev-wiz-next', disabled);
	},

	go: function(step) {
		this.st.step = step;
		this.save();
		this.redraw();
		window.scrollTo(0, 0);
	},

	handleBack: function() {
		if (this.busy)
			return;
		this.go(Math.max(STEP_WELCOME, this.st.step - 1));
	},

	handleNext: function() {
		if (this.busy)
			return;
		this.go(this.st.step + 1);
	},

	/* ---------- step 1: welcome ---------- */

	renderWelcome: function() {
		const ws = this.wstate;
		const configured = !ws.needed && (ws.node_ok || ws.enabled);
		const body = [
			E('p', {}, _('Easy VLESS sends the traffic of this router and of your devices through a VLESS or Trojan server (sing-box), while Russian sites stay direct.')),
			E('p', {}, _('This wizard sets it up in a few steps:')),
			E('ol', {}, [
				E('li', {}, _('paste the vless:// link of your server or the subscription link of your provider;')),
				E('li', {}, _('choose a server and check that it works;')),
				E('li', {}, _('choose what goes through the server;')),
				E('li', {}, _('review and start Easy VLESS.'))
			]),
			E('p', {}, _('Nothing on the router changes before the last step, except that the server or the subscription is added to Node List.'))
		];
		if (configured)
			body.push(E('div', { 'class': 'alert-message warning', 'id': 'ev-wiz-configured' }, [
				E('p', {}, _('Easy VLESS is already set up on this router. The wizard does not replace your settings: it adds a server or a subscription, changes the routing only if you choose so, and Review lists every change before anything is applied.'))
			]));
		else if (ws.completed)
			body.push(E('p', { 'class': 'cbi-value-description' }, _('The setup was completed before; you can run it again.')));
		if (ws.backup)
			body.push(E('div', { 'class': 'alert-message warning', 'id': 'ev-wiz-leftover' }, [
				E('p', {}, _('An earlier Apply of the wizard did not finish (the page was closed or the router restarted). The configuration saved before it can be restored.')),
				this.button(_('Restore previous configuration'), 'cbi-button-negative', 'handleRestoreLeftover', 'ev-wiz-restore')
			]));
		return {
			body: body,
			left: [ this.cancelButton() ],
			right: [ this.nextButton(_('Start setup')) ]
		};
	},

	handleRestoreLeftover: function() {
		this.busy = true;
		this.redraw();
		ev.showBusy(_('Restore'), _('Restoring the configuration saved before the unfinished Apply…'));
		return this.restore().then(L.bind(function(r) {
			this.busy = false;
			if (r.ok) {
				this.wstate.backup = false;
				ev.showResult(_('Restore'), 'ok', _('The previous configuration was restored.'));
			}
			else
				ev.showResult(_('Restore'), 'bad', _('Restore failed'), r.error);
			return this.reloadUci();
		}, this)).then(L.bind(this.redraw, this));
	},

	/* ---------- step 2: link (VLESS link or subscription link) ---------- */

	renderLink: function() {
		const st = this.st;
		const servers = ev.servers();
		const self = this;
		const body = [ E('p', {}, _('Paste the vless:// or trojan:// link of your server or the subscription link (https://…) of your provider. Your provider gives it to you (often as "Copy link" or as a QR code in the app).')) ];

		const choice = function(value, label, content) {
			const input = E('input', { 'type': 'radio', 'name': 'ev-wiz-mode', 'value': value, 'checked': st.mode == value ? '' : null });
			input.addEventListener('change', function() { st.mode = value; st.error = null; self.save(); self.redraw(); });
			return E('label', { 'class': 'ev-wiz-choice' + (st.mode == value ? ' selected' : ''), 'id': 'ev-wiz-mode-' + value }, [ input, E('strong', {}, label), content || '' ]);
		};

		const ta = E('textarea', { 'class': 'cbi-input-textarea', 'id': 'ev-wiz-url', 'rows': 4, 'spellcheck': 'false',
			'placeholder': 'vless://uuid@server:443?security=reality&sni=...#Name\nhttps://provider.example/your-link' }, st.url || '');
		const detectEl = E('div', { 'class': 'ev-wiz-detect', 'id': 'ev-wiz-detect' });
		const optsEl = E('div', { 'id': 'ev-wiz-subopts' });
		const update = function() {
			const d = detectInput(ta.value);
			dom.content(detectEl, !ta.value.trim() ? '' : ((d.kind == 'vless' || d.kind == 'trojan')
				? [ ev.badge(d.kind == 'trojan' ? _('Trojan link') : _('VLESS link'), 'info'), ' ', _('one server; it is added to Node List') ]
				: (d.kind == 'sub' ? [ ev.badge(_('Subscription link'), 'info'), ' ', _('the list of servers is downloaded by the router and checked') ] : '')));
			detectEl.setAttribute('data-kind', d.kind || '');
			optsEl.style.display = (d.kind == 'sub') ? '' : 'none';
			const next = document.getElementById('ev-wiz-next');
			if (next)
				next.textContent = self.linkLoaded() ? _('Next') : (d.kind == 'sub' ? _('Load subscription') : _('Add server'));
		};
		ta.addEventListener('input', function() {
			st.url = ta.value;
			st.error = null;
			self.save();
			const err = document.getElementById('ev-wiz-error');
			if (err) err.textContent = '';
			update();
		});

		/* subscription request options (Node List -> URL Subscriptions) */
		const hwid = E('input', { 'type': 'checkbox', 'id': 'ev-wiz-hwid', 'checked': st.subHwid ? '' : null,
			'change': function() { st.subHwid = hwid.checked; self.save(); } });
		const ua = E('select', { 'class': 'cbi-input-select', 'id': 'ev-wiz-ua', 'change': function() { st.subUa = ua.value; self.save(); } }, [
			[ 'auto', _('Auto (curl, then HAPP if needed)') ], [ '', _('Default (curl)') ], [ 'HAPP', 'HAPP' ]
		].map(function(o) { return E('option', { 'value': o[0], 'selected': (st.subUa || '') == o[0] ? '' : null }, o[1]); }));
		dom.content(optsEl, E('details', { 'class': 'ev-wiz-opts', 'open': (st.subHwid || st.subUa != 'auto') ? '' : null }, [
			E('summary', {}, _('Subscription options')),
			E('label', {}, [ hwid, ' ', _('Send the device ID (HWID) - for providers that limit the number of devices') ]),
			E('label', {}, [ _('User-Agent') + ': ', ua ]),
			E('p', { 'class': 'cbi-value-description' }, _('Auto: a normal request first; only if the provider answers with an error or without a supported server, one more request as the HAPP app.'))
		]));

		const importBox = E('div', { 'style': 'margin-top:.5em' }, [ ta, detectEl, optsEl ]);
		if (servers.length) {
			body.push(choice('paste', _('Paste a server link or a subscription link'), st.mode == 'paste' ? importBox : ''));
			body.push(choice('existing', _('Use a server that is already in Node List'),
				st.mode == 'existing' ? E('div', { 'class': 'ev-wiz-descr' }, _('%d servers; you choose one in the next step.').format(servers.length)) : ''));
		}
		else {
			st.mode = 'paste';
			body.push(importBox);
		}
		body.push(E('div', { 'class': 'ev-wiz-error', 'id': 'ev-wiz-error' }, st.error || ''));
		body.push(E('p', { 'class': 'cbi-value-description' }, _('VLESS and Trojan are supported (TCP, WebSocket, gRPC, HTTPUpgrade; TLS or Reality). Subscriptions: plain or base64 lists of vless:// and trojan:// links, Clash YAML and sing-box JSON; other server types are skipped.')));

		const d = detectInput(st.url);
		const label = (st.mode == 'existing' || this.linkLoaded()) ? _('Next') : (d.kind == 'sub' ? _('Load subscription') : _('Add server'));
		window.setTimeout(update, 0);
		return {
			body: body,
			left: [ this.cancelButton() ],
			right: [ this.backButton(), this.nextButton(label, 'handleLinkNext') ]
		};
	},

	/* the pasted link was already imported / loaded in this run */
	linkLoaded: function() {
		const st = this.st;
		const url = (st.url || '').trim();
		if (!url)
			return false;
		if (st.importedId && this.serverOk(st.importedId) && st.importedUrl == url)
			return true;
		return !!st.subId && this.subOk(st.subId) && st.subUrl == url && this.candidatesOf('sub').length > 0;
	},

	candidatesOf: function(source) {
		const saved = this.st.source;
		this.st.source = source;
		const list = this.candidates();
		this.st.source = saved;
		return list;
	},

	setError: function(text) {
		this.st.error = text;
		this.save();
		const el = document.getElementById('ev-wiz-error');
		if (el)
			el.textContent = text || '';
	},

	setNextLabel: function(text) {
		const next = document.getElementById('ev-wiz-next');
		if (next) { next.disabled = true; next.textContent = text; }
	},

	handleLinkNext: function() {
		const st = this.st;
		if (this.busy)
			return;
		if (st.mode == 'existing') {
			if (!ev.servers().length)
				return this.setError(_('There is no server in Node List yet.'));
			st.source = 'existing';
			if (!this.serverOk(st.serverId))
				st.serverId = ev.servers()[0]['.name'];
			st.error = null;
			return this.go(STEP_SERVER);
		}
		const url = (st.url || '').trim();
		if (this.linkLoaded()) {
			if (st.importedId && st.importedUrl == url) {
				st.source = 'vless';
				st.candidates = [ st.importedId ];
				st.serverId = st.importedId;
			}
			else {
				st.source = 'sub';
				if (this.candidates().indexOf(st.serverId) < 0)
					st.serverId = this.candidates()[0];
			}
			return this.go(STEP_SERVER);
		}
		const d = detectInput(url);
		if (d.error)
			return this.setError(d.error);
		return d.kind == 'sub' ? this.loadSubscription(url) : this.importVless(url);
	},

	importVless: function(url) {
		const st = this.st;
		this.busy = true;
		this.setError(null);
		this.setNextLabel(_('Adding…'));
		/* a server or subscription added earlier in this wizard run and
		 * replaced by another link is removed (never one that is in use) */
		return this.dropAdded().then(function() {
			return ev.callImport(url);
		}).then(L.bind(function(res) {
			if (res.rpc_error)
				throw new Error(_('The router did not answer: %s').format(res.error));
			const n = L.toArray(res.nodes)[0];
			if (!(res.added > 0) || !n)
				throw new Error(_('The link was not accepted by the parser.') + (importReason(res) ? '\n' + importReason(res) : ''));
			st.importedId = n.id;
			st.importedUrl = url;
			st.source = 'vless';
			st.candidates = [ n.id ];
			st.serverId = n.id;
			delete st.tests[n.id];
			return this.reloadUci();
		}, this)).then(L.bind(function() {
			this.busy = false;
			st.error = null;
			this.go(STEP_SERVER);
		}, this)).catch(L.bind(function(e) {
			this.busy = false;
			this.redraw();
			this.setError((e && e.message) ? e.message : String(e));
		}, this));
	},

	/* A subscription name derived from the host of its link, unique among
	 * the subscriptions (nodes belong to their subscription by this name). */
	subName: function(url) {
		const host = ((url.match(/^https?:\/\/(?:[^@\/?#]*@)?([^:\/?#]+)/i) || [])[1] || 'subscription').replace(/^www\./, '');
		const taken = uci.sections(CONFIG, 'subscribe_list').map(function(s) { return (s.remark || '').toLowerCase(); });
		let name = host, i = 2;
		while (taken.indexOf(name.toLowerCase()) > -1)
			name = host + ' ' + (i++);
		return name;
	},

	/* An http(s) link: add it as a URL Subscription (or reuse the one with the
	 * same link), download and parse it on the router (subscribe.lua), and
	 * offer its VLESS servers. Nothing counts as a subscription until the
	 * router found at least one supported server in it. */
	loadSubscription: function(url) {
		const st = this.st;
		this.busy = true;
		this.setError(null);
		this.setNextLabel(_('Loading…'));
		const detect = document.getElementById('ev-wiz-detect');
		if (detect)
			dom.content(detect, [ E('span', { 'class': 'spinning', 'style': 'display:inline-block;width:1em' }, ' '), ' ', _('Downloading the subscription on the router…') ]);
		let id, created = false;
		return this.dropAdded().then(L.bind(function() {
			const same = uci.sections(CONFIG, 'subscribe_list').filter(function(s) { return (s.url || '').trim() == url; })[0];
			if (same) {
				id = same['.name'];
				return;
			}
			id = ev.newName('sub_');
			created = true;
			uci.add(CONFIG, 'subscribe_list', id);
			uci.set(CONFIG, id, 'remark', this.subName(url));
			uci.set(CONFIG, id, 'url', url);
			uci.set(CONFIG, id, 'allowInsecure', '0');
			if (st.subUa)
				uci.set(CONFIG, id, 'user_agent', st.subUa);
			if (st.subHwid)
				uci.set(CONFIG, id, 'hwid', '1');
			return ev.saveAndCommit(null);
		}, this)).then(L.bind(function() {
			st.subId = id;
			st.subUrl = url;
			st.subCreated = created;
			this.save();
			return ev.updateSubscription(id);
		}, this)).then(L.bind(function(r) {
			return this.reloadUci().then(function() { return r; });
		}, this)).then(L.bind(function(r) {
			st.source = 'sub';
			const list = this.candidates();
			if (r.ok && list.length) {
				if (list.indexOf(st.serverId) < 0)
					st.serverId = list[0];
				this.busy = false;
				st.error = null;
				return this.go(STEP_SERVER);
			}
			/* no server: not a usable subscription - the one added here is
			 * removed again, nothing else changed */
			const reason = !r.ok ? (r.error || _('Failed')) : (ev.subResultText(id).text + (ev.subResultText(id).detail ? ' (' + ev.subResultText(id).detail + ')' : ''));
			return (created ? this.removeSubscription(id) : Promise.resolve()).then(L.bind(function() {
				st.subId = st.subUrl = null;
				st.subCreated = false;
				throw new Error(_('No VLESS or Trojan server was found in this subscription: %s').format(reason) + '\n' +
					_('Check the link. If your provider limits devices, enable "Send the device ID (HWID)" in the subscription options; if it serves the list only to the HAPP app, choose User-Agent HAPP.'));
			}, this));
		}, this)).catch(L.bind(function(e) {
			this.busy = false;
			this.redraw();
			this.setError((e && e.message) ? e.message : String(e));
		}, this));
	},

	/* Remove a subscription added by the wizard and its servers (servers
	 * still used somewhere are kept). */
	removeSubscription: function(id) {
		if (!this.subOk(id))
			return Promise.resolve();
		const remark = (uci.get(CONFIG, id, 'remark') || '').toLowerCase();
		ev.servers().forEach(function(s) {
			if (s.add_mode == '2' && (s.group || '').toLowerCase() == remark && !ev.references(s['.name']).length)
				uci.remove(CONFIG, s['.name']);
		});
		uci.remove(CONFIG, id);
		return ev.saveAndCommit(null).then(L.bind(this.reloadUci, this));
	},

	/* Remove what this wizard run added (the imported server, the
	 * subscription it created), unless something uses it. */
	dropAdded: function() {
		const st = this.st;
		const id = st.importedId;
		const sub = st.subCreated ? st.subId : null;
		st.importedId = st.importedUrl = null;
		st.subId = st.subUrl = null;
		st.subCreated = false;
		st.candidates = [];
		if (st.serverId == id || st.source == 'sub')
			st.serverId = null;
		this.save();
		let p = Promise.resolve();
		if (id && this.serverOk(id) && !ev.references(id).length) {
			uci.remove(CONFIG, id);
			p = ev.saveAndCommit(null).then(L.bind(this.reloadUci, this));
		}
		if (sub)
			p = p.then(L.bind(this.removeSubscription, this, sub));
		return p;
	},

	/* ---------- step 3: server ---------- */

	renderServer: function() {
		const st = this.st;
		const list = this.candidates();
		const self = this;
		const body = [];
		if (st.source == 'vless')
			body.push(E('div', { 'id': 'ev-wiz-imported' }, [
				E('p', {}, [ ev.badge(_('Added'), 'ok'), ' ', _('The server was added to Node List with these settings:') ]),
				kv(serverRows(list[0]))
			]));
		else if (st.source == 'sub')
			body.push(E('p', { 'id': 'ev-wiz-subinfo' }, [ ev.badge(_('Subscription'), 'ok'), ' ',
				_('Subscription "%s": %d servers were added to Node List. Choose the server to use:').format(uci.get(CONFIG, st.subId, 'remark') || '', list.length) ]));
		else
			body.push(E('p', {}, _('Choose the server to use:')));

		if (st.source != 'vless') {
			const rows = list.map(function(sid) {
				const g = function(k) { return uci.get(CONFIG, sid, k) || ''; };
				const input = E('input', { 'type': 'radio', 'name': 'ev-wiz-server', 'value': sid, 'checked': st.serverId == sid ? '' : null });
				const tr = E('tr', { 'class': st.serverId == sid ? 'selected' : '', 'data-sid': sid }, [
					E('td', {}, input),
					E('td', {}, [ E('strong', {}, g('remarks') || sid), E('div', {}, E('small', { 'style': 'opacity:.75' }, g('address') + ':' + g('port'))) ]),
					E('td', { 'class': 'ev-wiz-hide-sm' }, transportText(sid) + ' · ' + securityText(sid)),
					E('td', { 'id': 'ev-wiz-lat-' + sid }, ev.testCell(sid, 'server'))
				]);
				tr.addEventListener('click', function() {
					st.serverId = sid;
					self.save();
					input.checked = true;
					document.querySelectorAll('#ev-wiz-nodes tr').forEach(function(r) { r.classList.toggle('selected', r === tr); });
				});
				return tr;
			});
			body.push(E('table', { 'class': 'ev-wiz-nodes', 'id': 'ev-wiz-nodes' }, rows));
			if (list.length > 1)
				body.push(E('div', { 'style': 'margin-top:.5em;display:flex;gap:.5em;align-items:center;flex-wrap:wrap' }, [
					this.button(_('Test All'), '', 'handleTestCandidates', 'ev-wiz-testall'),
					E('small', { 'class': 'cbi-value-description', 'id': 'ev-wiz-testall-note' }, _('Optional: a Server Test of every server here, one after another, to see which ones answer.'))
				]));
		}
		if (!this.serverOk(st.serverId) || list.indexOf(st.serverId) < 0)
			st.serverId = list[0] || null;
		return {
			body: body,
			left: [ this.cancelButton() ],
			right: [ this.backButton(), this.nextButton(_('Next'), 'handleServerNext', !st.serverId) ]
		};
	},

	refreshNodeTests: function() {
		this.candidates().forEach(function(sid) {
			const el = document.getElementById('ev-wiz-lat-' + sid);
			if (el) dom.content(el, ev.testCell(sid, 'server'));
		});
		const st = ev.testState;
		const b = document.getElementById('ev-wiz-testall');
		if (b) b.disabled = this.busy || (st.running && (st.queue.length > 0 || !!st.current));
	},

	handleTestCandidates: function() {
		return ev.queueTests('server', this.candidates());
	},

	handleServerNext: function() {
		const st = this.st;
		if (this.busy)
			return;
		const sel = document.querySelector('#ev-wiz-nodes input[name=ev-wiz-server]:checked');
		if (sel)
			st.serverId = sel.value;
		if (!this.serverOk(st.serverId))
			return;
		this.go(STEP_TEST);
	},

	/* ---------- step 4: server test, then URL test ---------- */

	renderTest: function() {
		const st = this.st;
		const sid = st.serverId;
		const t = st.tests[sid] || {};
		const body = [
			E('p', {}, _('Easy VLESS now connects through the server with a temporary sing-box instance: first the Server Test, then the URL Test (real HTTPS requests through the server connection, not only a TCP connect).')),
			kv(serverRows(sid)),
			E('h4', {}, _('Result')),
			kv([
				[ _('Server Test'), E('span', { 'id': 'ev-wiz-servertest' }, testLine(t.server, ev.SERVER_TEST_URL)) ],
				[ _('URL Test'), E('span', { 'id': 'ev-wiz-urltest' }, testLine(t.url, ev.URL_TEST_URL)) ]
			])
		];
		const done = this.testsDone(t);
		if (done) {
			if (t.server.ok && t.url.ok)
				body.push(E('div', { 'class': 'alert-message success', 'id': 'ev-wiz-verdict', 'data-verdict': 'ok' }, _('The server works.')));
			else if (t.server.ok)
				body.push(E('div', { 'class': 'alert-message warning', 'id': 'ev-wiz-verdict', 'data-verdict': 'warn' },
					_('The server works, but %s did not answer through it. You can repeat the URL Test or continue.').format(ev.URL_TEST_URL)));
			else
				body.push(E('div', { 'class': 'alert-message error', 'id': 'ev-wiz-verdict', 'data-verdict': 'bad' }, [
					E('p', {}, _('The server did not work. Check the link (address, port, UUID, Reality key), that the server is online, and the router\'s internet connection.')),
					E('p', {}, _('You can repeat the test, go back and choose another server, or continue anyway (Easy VLESS then starts, but the traffic through this server will not work).'))
				]));
		}
		const failed = done && !t.server.ok;
		/* entering the step starts the tests once (or waits for the running ones) */
		if (!done && !this.busy)
			window.setTimeout(L.bind(this.runTests, this, false), 0);
		const right = [ this.backButton(), this.button(_('Repeat test'), '', 'handleRetest', 'ev-wiz-retest', !done) ];
		if (done && t.server.ok && !t.url.ok)
			right.push(this.button(_('Repeat URL Test'), '', 'handleRetestUrl', 'ev-wiz-retest-url'));
		right.push(failed ? this.nextButton(_('Continue anyway'), 'handleNext') : this.nextButton(_('Next'), 'handleNext', !done));
		return {
			body: body,
			left: [ this.cancelButton() ],
			right: right
		};
	},

	testsDone: function(t) {
		return !!(t && t.server && !t.server.pending && t.url && !t.url.pending);
	},

	/* The result of a test that was running while this page was away. */
	finishedMeanwhile: function(sid, kind, pending) {
		const info = ev.testInfo(sid, kind);
		if (info.state == 'testing' || info.state == 'queued')
			return null;
		const r = (ev.testState.results[sid] || {})[kind];
		return (r && pending && pending.since && r.time >= pending.since) ? r : null;
	},

	/* Server Test, then (only when it passed) URL Test. which: false = the
	 * missing ones, 'all' = both again, 'url' = the URL Test again. */
	runTests: function(which) {
		const st = this.st;
		const sid = st.serverId;
		if (this.busy || !sid)
			return;
		this.busy = true;
		const now = Math.floor(Date.now() / 1000 - ev.testSkew) - 2;
		const t = st.tests[sid] = st.tests[sid] || {};
		/* kind -> the result to use: a finished result, one that finished
		 * while this page was away, or null = run (or wait for) the test */
		const pick = L.bind(function(kind, again) {
			const cur = t[kind];
			if (again || !cur || cur.skipped)
				return null;
			if (cur.pending)
				return this.finishedMeanwhile(sid, kind, cur);
			return cur;
		}, this);
		const server = pick('server', which == 'all');
		const url = server ? pick('url', which == 'all' || which == 'url') : null;
		t.server = server || { pending: true, since: (t.server && t.server.pending && t.server.since) || now };
		t.url = url || { pending: true, since: (t.url && t.url.pending && t.url.since) || now };
		this.save();
		this.redraw();
		const step = server ? Promise.resolve(server) : ev.serverTest(sid);
		return step.then(L.bind(function(r) {
			t.server = r;
			this.save();
			if (this.st.step == STEP_TEST) this.redraw();
			if (!r.ok)
				return { skipped: true };
			return url ? url : ev.nodeUrlTest(sid);
		}, this)).then(L.bind(function(r) {
			t.url = r;
		}, this)).catch(function(e) {
			if (t.server.pending) t.server = { ok: false, error: String(e) };
			if (t.url.pending) t.url = { ok: false, error: String(e) };
		}).then(L.bind(function() {
			this.busy = false;
			this.save();
			if (this.st.step == STEP_TEST)
				this.redraw();
		}, this));
	},

	handleRetest: function() {
		return this.runTests('all');
	},

	handleRetestUrl: function() {
		return this.runTests('url');
	},

	/* ---------- step 5: routing ---------- */

	renderRouting: function() {
		const st = this.st;
		const self = this;
		const server = st.serverId;
		const body = [ E('p', {}, _('Choose what goes through the server. Rules can be changed later in Rule Manage, their targets on Main.')) ];
		const choice = function(value, label, descr, disabled) {
			const input = E('input', { 'type': 'radio', 'name': 'ev-wiz-routing', 'value': value,
				'checked': st.routing == value ? '' : null, 'disabled': disabled ? '' : null });
			input.addEventListener('change', function() { st.routing = value; self.save(); self.redraw(); });
			return E('label', { 'class': 'ev-wiz-choice' + (st.routing == value ? ' selected' : ''), 'id': 'ev-wiz-routing-' + value }, [
				input, E('strong', {}, label), E('div', { 'class': 'ev-wiz-descr' }, descr)
			]);
		};
		const basicOk = TEMPLATES.length > 0;
		body.push(choice('basic', _('Recommended: Russian sites direct, everything else through the server'),
			basicOk ? kv(this.routingRows('basic', server)) : E('span', { 'class': 'ev-wiz-error' }, _('Not available: the prepared rules could not be read (%s).').format(RESOURCES_ERROR || _('no rule templates'))),
			!basicOk));
		body.push(choice('all', _('Everything through the server'), _('All traffic of the router and of the LAN devices goes through %s.').format(ev.label(server))));
		if (this.routingChoices().indexOf('keep') > -1)
			body.push(choice('keep', _('Keep the current routing'), E('div', {}, [
				_('The routing is not changed; the server is only added to Node List. Current routing:'),
				kv(this.routingRows('keep', server))
			])));
		if (st.routing == 'basic' && !basicOk)
			st.routing = 'all';
		return {
			body: body,
			left: [ this.cancelButton() ],
			right: [ this.backButton(), this.nextButton(_('Next')) ]
		};
	},

	/* ---------- step 6: review ---------- */

	renderReview: function() {
		const st = this.st;
		const server = st.serverId;
		const g = function(k, d) { const v = uci.get(CONFIG, 'global', k); return (v == null || v === '') ? d : v; };
		const f = function(k, d) { const v = uci.get(CONFIG, 'global_forwarding', k); return (v == null || v === '') ? d : v; };
		const onoff = function(v) { return v == '1' ? _('on') : _('off'); };
		const t = st.tests[server] || {};
		const remoteProto = g('remote_dns_protocol', 'tcp');
		const remote = remoteProto == 'doh' ? g('remote_dns_doh', 'https://1.1.1.1/dns-query') : (remoteProto.toUpperCase() + ' ' + g('remote_dns', '1.1.1.1'));
		const directProto = g('direct_dns_protocol', 'auto');
		const res = function(r) {
			if (!r || r.pending) return E('em', {}, _('not tested'));
			if (r.skipped) return E('em', {}, _('not run'));
			return r.ok ? E('span', {}, [ ev.badge(_('PASS'), 'ok'), ' ', _('%d ms').format(r.delay) ]) : ev.badge(_('FAIL'), 'bad');
		};

		const warnings = [];
		if (!t.server || t.server.pending)
			warnings.push(_('The server was not tested.'));
		else if (!t.server.ok)
			warnings.push(_('The Server Test failed: Easy VLESS starts, but the traffic through this server will not work.'));
		else if (t.url && !t.url.pending && !t.url.ok && !t.url.skipped)
			warnings.push(_('The URL Test failed: %s did not answer through the server.').format(ev.URL_TEST_URL));
		if (st.routing == 'all')
			warnings.push(_('Everything goes through the server, also Russian sites.'));

		const body = [
			E('p', {}, _('Check the settings. Apply saves them, checks the configuration with sing-box and starts Easy VLESS.')),
			E('h4', {}, _('Server')),
			kv(serverRows(server).concat([
				[ _('Server Test'), res(t.server) ],
				[ _('URL Test'), res(t.url) ]
			])),
			E('h4', {}, _('Routing')),
			E('div', { 'id': 'ev-wiz-review-routing' }, kv(this.routingRows(st.routing, server))),
			E('h4', {}, _('DNS')),
			kv([
				[ _('Proxied domains'), _('%s through the server').format(remote) + (g('remote_fakedns', '0') == '1' ? ', FakeDNS' : '') ],
				[ _('Direct domains'), directProto == 'auto' ? _('the provider\'s DNS (automatic)') : directProto.toUpperCase() + ' ' + g('direct_dns', '') ],
				[ _('DNS of LAN devices'), g('dns_redirect', '1') == '1' ? _('redirected to the router (dnsmasq → sing-box)') : _('not redirected') ]
			]),
			E('h4', {}, _('Forwarding')),
			kv([
				[ _('LAN devices'), g('client_proxy', '1') == '1' ? _('transparent proxy (%s)').format(f('tcp_proxy_way', 'tproxy').toUpperCase()) : _('not proxied') ],
				[ _('The router itself'), g('localhost_proxy', '1') == '1' ? _('proxied') : _('not proxied') ],
				[ _('Ports'), 'TCP ' + f('tcp_redir_ports', '1:65535') + ' · UDP ' + f('udp_redir_ports', '1:65535') ],
				[ _('IPv6 TProxy'), onoff(f('ipv6_tproxy', '0')) ]
			]),
			E('p', { 'class': 'cbi-value-description' }, _('DNS and forwarding keep their current values; change them later in Settings.')),
			warnings.length ? E('div', { 'class': 'alert-message warning', 'id': 'ev-wiz-warnings' }, E('ul', {}, warnings.map(function(w) { return E('li', {}, w); }))) : '',
			E('h4', {}, _('What Apply does')),
			E('ul', {}, [
				E('li', {}, st.routing == 'keep' ? _('the routing is not changed') : _('writes the routing above (Rule Manage / Main)')),
				E('li', {}, _('checks the configuration with sing-box; nothing starts if it is invalid')),
				E('li', {}, _('turns the main switch on: Easy VLESS starts now and on every boot')),
				E('li', {}, _('starts sing-box, the firewall rules (nft table inet easy_vless) and the DNS forwarding'))
			])
		];
		if (this.wstate.backup)
			body.push(E('div', { 'class': 'alert-message warning', 'id': 'ev-wiz-leftover' }, [
				E('p', {}, _('An earlier Apply of the wizard did not finish. Apply saves a new copy first; to go back to the configuration from before that earlier Apply, restore it now.')),
				this.button(_('Restore previous configuration'), 'cbi-button-negative', 'handleRestoreLeftover', 'ev-wiz-restore')
			]));
		return {
			body: body,
			left: [ this.cancelButton() ],
			right: [ this.backButton(), this.nextButton(_('Apply'), 'handleApply') ]
		};
	},

	/* ---------- step 7: apply ---------- */

	APPLY_ITEMS: [
		[ 'backup', _('Save a copy of the current configuration') ],
		[ 'save', _('Save the configuration') ],
		[ 'check', _('Check the configuration (sing-box check)') ],
		[ 'start', _('Start Easy VLESS') ],
		[ 'status', _('Check the service status') ],
		[ 'finish', _('Finish the setup') ]
	],

	renderApply: function() {
		const a = this.st.apply || { items: {} };
		const icon = function(s) {
			if (s == 'ok') return ev.badge('✓', 'ok');
			if (s == 'bad') return ev.badge('✗', 'bad');
			if (s == 'run') return E('span', { 'class': 'spinning' }, ' ');
			return E('span', { 'style': 'opacity:.5' }, '•');
		};
		const body = [
			E('ul', { 'class': 'ev-wiz-check', 'id': 'ev-wiz-apply' }, this.APPLY_ITEMS.map(function(it) {
				const s = a.items[it[0]];
				return E('li', { 'data-item': it[0], 'data-state': s || '' }, [ icon(s), ' ', it[1] ]);
			}))
		];
		if (a.failed) {
			body.push(E('div', { 'class': 'alert-message error', 'id': 'ev-wiz-apply-error' }, [
				E('p', {}, E('strong', {}, a.title)),
				E('p', {}, a.restored
					? _('The configuration from before Apply was restored; Easy VLESS was not left half-configured.')
					: _('Restoring the previous configuration failed: %s').format(a.restoreError || '?')),
				a.output ? E('pre', { 'style': 'white-space:pre-wrap;max-height:18em;overflow:auto;font-size:90%;background:rgba(0,0,0,.25);padding:.4em' }, a.output) : ''
			]));
			body.push(E('p', {}, _('Go back to change the server or the routing, or try Apply again.')));
		}
		const running = !a.failed && !a.ok;
		return {
			body: body,
			left: running ? [] : [ this.cancelButton() ],
			right: running ? [] : [ this.backButton(), this.nextButton(_('Try again'), 'handleApply') ]
		};
	},

	setItem: function(key, state) {
		this.st.apply.items[key] = state;
		this.save();
		if (this.st.step == STEP_APPLY)
			this.redraw();
	},

	/* Put the copy back and bring the service to the restored state. */
	restore: function() {
		return ev.callWizard('restore').then(L.bind(function(r) {
			if (r.rpc_error || !r.ok)
				return { ok: false, error: r.error || r.output };
			return ev.waitIdle(r.log_mark, 60000).then(function() { return { ok: true, service: r.service }; });
		}, this));
	},

	handleApply: function() {
		const st = this.st;
		const server = st.serverId;
		if (this.busy)
			return;
		if (!this.serverOk(server))
			return this.go(STEP_SERVER);
		this.busy = true;
		st.apply = { items: {} };
		st.result = null;
		this.go(STEP_APPLY);

		let stage = 'backup';
		const fail = L.bind(function(title, output) {
			this.setItem(stage, 'bad');
			return (stage == 'backup' ? Promise.resolve({ ok: true, skipped: true }) : this.restore()).then(L.bind(function(r) {
				st.apply.failed = true;
				st.apply.title = title;
				/* the reason is at the end of a start log: keep its last lines */
				st.apply.output = (output || '').split(/\n/).slice(-30).join('\n');
				st.apply.restored = !!r.ok;
				st.apply.restoreError = r.error;
				return this.reloadUci();
			}, this)).then(L.bind(function() {
				return ev.callWizardState();
			}, this)).then(L.bind(function(ws) {
				if (!ws.rpc_error)
					this.wstate = ws;
				this.busy = false;
				this.save();
				this.redraw();
			}, this));
		}, this);

		this.setItem('backup', 'run');
		return this.reloadUci().then(function() {
			return ev.callWizard('backup');
		}).then(L.bind(function(r) {
			if (r.rpc_error || !r.ok)
				return fail(_('Apply failed: the current configuration could not be saved. Nothing was changed.'), r.error || r.output);
			this.setItem('backup', 'ok');

			stage = 'save';
			this.setItem('save', 'run');
			this.applyPlan(this.routingPlan(st.routing, server), server);
			return ev.saveAndCommit(null).then(L.bind(function() {
				this.setItem('save', 'ok');
				return this.reloadUci();
			}, this), L.bind(function(e) {
				return ev.callUciRevert().then(function() {
					throw { ev_stage_failed: true, message: (e && e.message) ? e.message : String(e) };
				});
			}, this)).then(L.bind(function() {
				stage = 'check';
				this.setItem('check', 'run');
				return ev.callCheck('');
			}, this)).then(L.bind(function(res) {
				if (!(res.ok || res.code === 0))
					return fail(_('The configuration is invalid: Easy VLESS was not started.'), res.output || res.error);
				this.setItem('check', 'ok');

				stage = 'start';
				this.setItem('start', 'run');
				return ev.startService().then(L.bind(function(r) {
					if (!r.ok)
						return fail(r.stage == 'check'
							? _('The configuration is invalid: Easy VLESS was not started.')
							: (r.timeout ? _('Easy VLESS did not start in time.') : _('Easy VLESS did not start (the start was rolled back).')), r.output);
					this.setItem('start', 'ok');

					stage = 'status';
					this.setItem('status', 'run');
					const s = r.status || {};
					if (!s.running || !s.nft_table)
						return fail(_('Easy VLESS started, but its status is not complete (process: %s, firewall table: %s).')
							.format(s.running ? _('running') : _('not running'), s.nft_table ? _('present') : _('missing')), s.log);
					st.result = { pid: s.pid, singbox: s.singbox_version, rss_kb: s.rss_kb, nft: s.nft_table };
					this.setItem('status', 'ok');

					stage = 'finish';
					this.setItem('finish', 'run');
					return ev.callWizard('finish').then(L.bind(function(f) {
						if (f.rpc_error || !f.ok)
							return fail(_('Easy VLESS runs, but the setup could not be marked as finished.'), f.error || f.output);
						this.setItem('finish', 'ok');
						return ev.callWizard('connectivity').then(L.bind(function(c) {
							st.result.connectivity = c;
							st.apply.ok = true;
							this.busy = false;
							return this.reloadUci();
						}, this)).then(L.bind(function() {
							this.go(STEP_DONE);
						}, this));
					}, this));
				}, this));
			}, this));
		}, this)).catch(L.bind(function(e) {
			if (e && e.ev_stage_failed)
				return fail(_('Apply failed: the configuration could not be saved.'), e.message);
			return fail(_('Apply failed: %s').format((e && e.message) ? e.message : String(e)), '');
		}, this));
	},

	/* ---------- step 8: done ---------- */

	renderDone: function() {
		const st = this.st;
		const r = st.result || {};
		const c = r.connectivity || {};
		const server = st.serverId;
		const nav = function(label, path, id) {
			return E('a', { 'class': 'btn cbi-button', 'id': id, 'href': L.url('admin/services/easy_vless/' + path),
				'click': function() { clearState(); } }, label);
		};
		let conn;
		if (c.rpc_error || c.http_code == null)
			conn = ev.badge(_('unknown'), 'warn');
		else if (c.ok)
			conn = E('span', {}, [ ev.badge(_('OK', 'connection check result'), 'ok'), ' ', E('small', {}, 'HTTP ' + c.http_code + ' · ' + (c.url || '')) ]);
		else
			conn = E('span', {}, [ ev.badge(_('no answer'), 'warn'), ' ', E('small', {}, _('%s did not answer (HTTP %s). Check the Server Test on Main.').format(c.url || ev.SERVER_TEST_URL, c.http_code || '000')) ]);
		const g = function(k, d) { return uci.get(CONFIG, 'global', k) || d; };
		const remoteProto = g('remote_dns_protocol', 'tcp');
		return {
			body: [
				E('div', { 'class': 'alert-message success', 'id': 'ev-wiz-done' }, E('strong', {}, _('Easy VLESS is set up and running.'))),
				kv([
					[ _('Server'), server && this.serverOk(server) ? ev.label(server) : '-' ],
					(st.source == 'sub' && this.subOk(st.subId)) ? [ _('Subscription'), uci.get(CONFIG, st.subId, 'remark') || '' ] : null,
					[ _('Routing'), { basic: _('Russian sites direct, everything else through the server'), all: _('Everything through the server'), keep: _('unchanged') }[st.routing] || '-' ],
					[ _('DNS'), remoteProto == 'doh' ? g('remote_dns_doh', '') : remoteProto.toUpperCase() + ' ' + g('remote_dns', '1.1.1.1') ],
					[ _('Service'), E('span', {}, [ ev.badge(_('Running'), 'ok'), ' ', _('PID %s').format(r.pid || '?'), r.singbox ? ' · sing-box ' + r.singbox : '' ]) ],
					[ _('Connection'), E('span', { 'id': 'ev-wiz-connectivity' }, conn) ]
				]),
				E('p', {}, _('Main shows the status and the connection test, Node List manages servers and subscriptions, Rule Manage the rules.')),
				E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:.5em' }, [
					nav(_('Open Main'), 'main', 'ev-wiz-open-main'),
					nav(_('Open Node List'), 'servers', 'ev-wiz-open-servers'),
					nav(_('Open Rule Manage'), 'rules', 'ev-wiz-open-rules')
				])
			],
			left: [],
			right: [ this.button(_('Finish'), 'cbi-button-positive', 'handleFinish', 'ev-wiz-finish') ]
		};
	},

	handleFinish: function() {
		clearState();
		window.location.href = L.url('admin/services/easy_vless/main');
	},

	/* ---------- cancel ---------- */

	handleCancel: function() {
		if (this.busy)
			return;
		const st = this.st;
		const imported = st.importedId && this.serverOk(st.importedId) && !ev.references(st.importedId).length ? st.importedId : null;
		const sub = (st.subCreated && this.subOk(st.subId)) ? st.subId : null;
		const self = this;
		ui.showModal(_('Leave the setup?'), [
			E('p', {}, _('Nothing was applied: Easy VLESS and your settings stay as they are.')),
			imported ? E('p', {}, _('The server "%s" added in this setup is removed again.').format(uci.get(CONFIG, imported, 'remarks') || imported)) : '',
			sub ? E('p', {}, _('The subscription "%s" added in this setup and its servers are removed again.').format(uci.get(CONFIG, sub, 'remark') || sub)) : '',
			E('p', { 'class': 'cbi-value-description' }, _('You can open the setup again at any time: Services → Easy VLESS → Setup Wizard.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'id': 'ev-wiz-cancel-no', 'click': ui.hideModal }, _('Continue setup')),
				' ',
				E('button', { 'class': 'btn cbi-button-negative', 'id': 'ev-wiz-cancel-yes', 'click': function() {
					ui.hideModal();
					self.busy = true;
					((imported || sub) ? self.dropAdded() : Promise.resolve()).then(function() {
						ev.setWizardDismissed(true);
						clearState();
						window.location.href = L.url('admin/services/easy_vless/main');
					}).catch(function(e) {
						self.busy = false;
						ev.reportError(_('Cancel'), e);
						self.redraw();
					});
				} }, _('Leave setup'))
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
