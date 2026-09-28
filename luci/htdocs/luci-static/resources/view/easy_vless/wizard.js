'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require easy_vless.common as ev';

/*
 * Easy VLESS - First Run Wizard (0.6.0): onboarding only, no second
 * configuration system. Every step uses what Main, Node List and Rule Manage
 * already use:
 *   Add server   rpcd "import" (subscribe.lua VLESS parser, same as Node
 *                List -> Import VLESS URL), or an existing server
 *   Server Test  rpcd "urltest_node": temporary sing-box instance with the
 *                server's VLESS outbound, HTTPS to generate_204 (Server Test)
 *                and to https://x.com (URL Test)
 *   Routing      the prepared rules of the resource manifest (Rule Manage ->
 *                Add prepared rule, ev.applyTemplate) and the Main Router
 *                targets (main_router.<rule id>, main_router.default_node)
 *   Apply        uci commit, rpcd "check" (sing-box check) and "start"
 *                (the path of Main -> Save & Start); rpcd "wizard" keeps a
 *                copy of the committed configuration and puts it back when
 *                a step fails, so nothing stays half-applied
 * State: the step and the entered values live in this browser tab
 * (sessionStorage) until the wizard ends; the router only stores
 * easy_vless.global.wizard_completed=1 after a successful Apply.
 */

const CONFIG = ev.CONFIG;
const ROUTER = ev.ROUTER;
const STORE = 'easy_vless.wizard';

const STEP_WELCOME = 0, STEP_SERVER = 1, STEP_TEST = 2, STEP_ROUTING = 3, STEP_REVIEW = 4, STEP_APPLY = 5, STEP_DONE = 6;
const STEPS = [ _('Welcome'), _('Server'), _('Server Test'), _('Routing'), _('Review'), _('Apply'), _('Done') ];

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

/* One vless:// link, checked before it is sent to the router: a clear
 * reason instead of "0 imported". Returns an error text or null. */
function linkError(v) {
	v = (v || '').trim();
	if (!v)
		return _('Paste the vless:// link of your server.');
	const links = v.split(/\s+/).filter(function(x) { return x; });
	if (links.length > 1)
		return _('Paste exactly one link. More servers can be added later in Node List.');
	const m = v.match(/^([A-Za-z][A-Za-z0-9+.-]*):\/\//);
	if (!m)
		return _('This is not a link: a VLESS link starts with vless://');
	const scheme = m[1].toLowerCase();
	if (scheme == 'http' || scheme == 'https')
		return _('This looks like a subscription address, not a server link. Subscriptions are added in Node List → URL Subscriptions; here paste one vless:// link.');
	if (scheme != 'vless')
		return _('"%s://" links are not supported: Easy VLESS works with VLESS servers only (vless://).').format(scheme);
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
		[ _('Address'), (g('address') || '-') + ':' + (g('port') || '-') ],
		[ _('Transport'), transportText(sid) ],
		[ _('Security'), securityText(sid) ],
		g('tls') == '1' && g('tls_serverName') ? [ 'SNI', g('tls_serverName') ] : null,
		g('flow') ? [ 'Flow', g('flow') ] : null
	];
}

function testLine(r, url) {
	if (!r)
		return E('em', {}, _('not tested yet'));
	if (r.pending)
		return E('em', { 'class': 'spinning' }, _('testing…'));
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
			ev.callResources()
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
			mode: ev.servers().length ? 'existing' : 'import',
			url: '',
			serverId: null,
			importedId: null,
			importedUrl: null,
			routing: null,
			tests: {},
			apply: null,
			result: null
		};
	},

	serverOk: function(sid) {
		return !!sid && ev.isServer(sid);
	},

	reloadUci: function() {
		uci.unload(CONFIG);
		return uci.load(CONFIG);
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
			'.ev-wiz { max-width: 48em; }',
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
			'.ev-wiz-reason { white-space: pre-wrap; }',
			'.ev-wiz-kv { width: 100%; table-layout: fixed; }',
			'.ev-wiz-kv .td { padding: .25em .45em; overflow-wrap: anywhere; word-break: break-word; }',
			'.ev-wiz-descr { margin: .3em 0 0 1.6em; font-size: 95%; }',
			'.ev-wiz pre, .ev-wiz-error, .ev-wiz-reason { overflow-wrap: anywhere; }',
			'.ev-wiz-check li { margin: .25em 0; list-style: none; }',
			'.ev-wiz textarea { width: 100%; box-sizing: border-box; }',
			'@media (max-width: 600px) { .ev-wiz-steps li:not(.current) { display: none; } .ev-wiz-nav button { flex: 1 1 auto; } }'
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
		/* a server that no longer exists (deleted in Node List meanwhile) */
		if (st.serverId && !this.serverOk(st.serverId))
			st.serverId = null;
		if (st.importedId && !this.serverOk(st.importedId))
			st.importedId = st.importedUrl = null;
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
		const fn = [ 'renderWelcome', 'renderServer', 'renderTest', 'renderRouting', 'renderReview', 'renderApply', 'renderDone' ][st.step];
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
			E('p', {}, _('Easy VLESS sends the traffic of this router and of your devices through a VLESS server (sing-box), while Russian sites stay direct.')),
			E('p', {}, _('This wizard sets it up in a few steps:')),
			E('ol', {}, [
				E('li', {}, _('add your VLESS server (a vless:// link from your provider);')),
				E('li', {}, _('check that the server works;')),
				E('li', {}, _('choose what goes through the server;')),
				E('li', {}, _('review and start Easy VLESS.'))
			]),
			E('p', {}, _('You need the vless:// link of your server. Nothing on the router changes before the last step.'))
		];
		if (configured)
			body.push(E('div', { 'class': 'alert-message warning', 'id': 'ev-wiz-configured' }, [
				E('p', {}, _('Easy VLESS is already set up on this router. The wizard does not replace your settings: it adds a server, changes the routing only if you choose so in step 4, and Review lists every change before anything is applied.'))
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

	/* ---------- step 2: server ---------- */

	renderServer: function() {
		const st = this.st;
		const servers = ev.servers();
		const self = this;
		const body = [ E('p', {}, _('Paste the vless:// link of your server. Your provider gives it to you (often as "Copy link" or as a QR code in the app).')) ];

		const choice = function(value, label, content) {
			const input = E('input', { 'type': 'radio', 'name': 'ev-wiz-mode', 'value': value, 'checked': st.mode == value ? '' : null });
			input.addEventListener('change', function() { st.mode = value; st.error = null; self.save(); self.redraw(); });
			return E('label', { 'class': 'ev-wiz-choice' + (st.mode == value ? ' selected' : ''), 'id': 'ev-wiz-mode-' + value }, [ input, E('strong', {}, label), content || '' ]);
		};

		const ta = E('textarea', { 'class': 'cbi-input-textarea', 'id': 'ev-wiz-url', 'rows': 4, 'spellcheck': 'false',
			'placeholder': 'vless://uuid@server:443?security=reality&sni=...#Name' }, st.url || '');
		ta.addEventListener('input', function() {
			st.url = ta.value;
			st.error = null;
			self.save();
			const err = document.getElementById('ev-wiz-error');
			if (err) err.textContent = '';
			const next = document.getElementById('ev-wiz-next');
			if (next) next.textContent = self.importedCurrent() ? _('Next') : _('Add server');
			/* the "Added" box belongs to the previous link only */
			const box = document.getElementById('ev-wiz-imported');
			if (box) box.style.display = self.importedCurrent() ? '' : 'none';
		});

		const importBox = E('div', { 'style': 'margin-top:.5em' }, [ ta ]);
		if (servers.length) {
			const sel = E('select', { 'class': 'cbi-input-select', 'id': 'ev-wiz-existing', 'style': 'margin-top:.4em;max-width:100%' }, servers.map(function(s) {
				return E('option', { 'value': s['.name'], 'selected': (s['.name'] == st.serverId) ? '' : null }, ev.label(s['.name']) + ' (' + (s.address || '') + ':' + (s.port || '') + ')');
			}));
			sel.addEventListener('change', function() { st.existingId = sel.value; self.save(); });
			if (!st.existingId || !this.serverOk(st.existingId))
				st.existingId = (st.serverId && this.serverOk(st.serverId)) ? st.serverId : servers[0]['.name'];
			sel.value = st.existingId;
			body.push(choice('import', _('Paste a new VLESS link'), st.mode == 'import' ? importBox : ''));
			body.push(choice('existing', _('Use a server that is already in Node List'), st.mode == 'existing' ? E('div', {}, sel) : ''));
		}
		else {
			st.mode = 'import';
			body.push(importBox);
		}
		body.push(E('div', { 'class': 'ev-wiz-error', 'id': 'ev-wiz-error' }, st.error || ''));

		if (st.mode == 'import' && this.importedCurrent())
			body.push(E('div', { 'id': 'ev-wiz-imported' }, [
				E('p', {}, [ ev.badge(_('Added'), 'ok'), ' ', _('The server was added to Node List with these settings:') ]),
				kv(serverRows(st.importedId))
			]));
		body.push(E('p', { 'class': 'cbi-value-description' }, _('Only VLESS is supported (TCP, WebSocket, gRPC, HTTPUpgrade; TLS or Reality). A subscription URL can be added later in Node List.')));

		const label = (st.mode == 'existing' || this.importedCurrent()) ? _('Next') : _('Add server');
		return {
			body: body,
			left: [ this.cancelButton() ],
			right: [ this.backButton(), this.nextButton(label, 'handleServerNext') ]
		};
	},

	importedCurrent: function() {
		const st = this.st;
		return !!st.importedId && this.serverOk(st.importedId) && st.importedUrl == (st.url || '').trim();
	},

	setError: function(text) {
		this.st.error = text;
		this.save();
		const el = document.getElementById('ev-wiz-error');
		if (el)
			el.textContent = text || '';
	},

	handleServerNext: function() {
		const st = this.st;
		if (this.busy)
			return;
		if (st.mode == 'existing') {
			const sel = document.getElementById('ev-wiz-existing');
			const sid = sel ? sel.value : st.existingId;
			if (!this.serverOk(sid))
				return this.setError(_('Select a server.'));
			st.serverId = sid;
			st.error = null;
			return this.go(STEP_TEST);
		}
		const url = (st.url || '').trim();
		if (this.importedCurrent()) {
			st.serverId = st.importedId;
			return this.go(STEP_TEST);
		}
		const err = linkError(url);
		if (err)
			return this.setError(err);

		this.busy = true;
		this.setError(null);
		const next = document.getElementById('ev-wiz-next');
		if (next) { next.disabled = true; next.textContent = _('Adding…'); }
		/* a server imported earlier in this wizard run and replaced by another
		 * link is removed (never a server that is in use) */
		return this.dropImported().then(function() {
			return ev.callImport(url);
		}).then(L.bind(function(res) {
			if (res.rpc_error)
				throw new Error(_('The router did not answer: %s').format(res.error));
			const n = L.toArray(res.nodes)[0];
			if (!(res.added > 0) || !n)
				throw new Error(_('The link was not accepted by the VLESS parser.') + (importReason(res) ? '\n' + importReason(res) : ''));
			st.importedId = n.id;
			st.importedUrl = url;
			st.serverId = n.id;
			delete st.tests[n.id];
			return this.reloadUci();
		}, this)).then(L.bind(function() {
			this.busy = false;
			st.error = null;
			this.save();
			this.redraw();
		}, this)).catch(L.bind(function(e) {
			this.busy = false;
			this.redraw();
			this.setError((e && e.message) ? e.message : String(e));
		}, this));
	},

	/* Remove the server this wizard run imported, unless something uses it. */
	dropImported: function() {
		const st = this.st;
		const id = st.importedId;
		st.importedId = st.importedUrl = null;
		if (st.serverId == id)
			st.serverId = null;
		this.save();
		if (!id || !this.serverOk(id) || ev.references(id).length)
			return Promise.resolve();
		uci.remove(CONFIG, id);
		return ev.saveAndCommit(null).then(L.bind(this.reloadUci, this));
	},

	/* ---------- step 3: server test ---------- */

	renderTest: function() {
		const st = this.st;
		const sid = st.serverId;
		const t = st.tests[sid] || {};
		const body = [
			E('p', {}, _('Easy VLESS now connects through the server with a temporary sing-box instance and opens two web addresses over HTTPS (a real request through the VLESS connection, not only a TCP connect).')),
			kv(serverRows(sid)),
			E('h4', {}, _('Result')),
			kv([
				[ _('Server Test'), E('span', { 'id': 'ev-wiz-servertest' }, testLine(t.server, ev.SERVER_TEST_URL)) ],
				[ _('URL Test'), E('span', { 'id': 'ev-wiz-urltest' }, testLine(t.url, ev.URL_TEST_URL)) ]
			])
		];
		let verdict;
		if (t.server && !t.server.pending && t.url && !t.url.pending) {
			if (t.server.ok && t.url.ok)
				verdict = E('div', { 'class': 'alert-message success', 'id': 'ev-wiz-verdict', 'data-verdict': 'ok' }, _('The server works.'));
			else if (t.server.ok)
				verdict = E('div', { 'class': 'alert-message warning', 'id': 'ev-wiz-verdict', 'data-verdict': 'warn' },
					_('The server works, but %s did not answer through it. You can continue.').format(ev.URL_TEST_URL));
			else
				verdict = E('div', { 'class': 'alert-message error', 'id': 'ev-wiz-verdict', 'data-verdict': 'bad' }, [
					E('p', {}, _('The server did not work. Check the link (address, port, UUID, Reality key), that the server is online, and the router\'s internet connection.')),
					E('p', {}, _('You can repeat the test, go back and paste another link, or continue anyway (Easy VLESS then starts, but the traffic through this server will not work).'))
				]);
			body.push(verdict);
		}
		const done = t.server && !t.server.pending && t.url && !t.url.pending;
		const failed = done && !t.server.ok;
		/* entering the step starts the test once */
		if (!t.server && !this.busy)
			window.setTimeout(L.bind(this.handleRetest, this), 0);
		return {
			body: body,
			left: [ this.cancelButton() ],
			right: [ this.backButton(),
				this.button(_('Repeat test'), '', 'handleRetest', 'ev-wiz-retest', !done),
				failed ? this.nextButton(_('Continue anyway'), 'handleNext') : this.nextButton(_('Next'), 'handleNext', !done) ]
		};
	},

	handleRetest: function() {
		const st = this.st;
		const sid = st.serverId;
		if (this.busy || !sid)
			return;
		this.busy = true;
		const t = st.tests[sid] = { server: { pending: true }, url: { pending: true } };
		this.redraw();
		return ev.serverTest(sid).then(L.bind(function(r) {
			t.server = r;
			this.save();
			this.redraw();
			return ev.nodeUrlTest(sid);
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

	/* ---------- step 4: routing ---------- */

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
		body.push(choice('basic', _('Recommended: Russian sites direct, everything else through VLESS'),
			basicOk ? kv(this.routingRows('basic', server)) : E('span', { 'class': 'ev-wiz-error' }, _('Not available: the prepared rules could not be read (%s).').format(RESOURCES_ERROR || _('no rule templates'))),
			!basicOk));
		body.push(choice('all', _('Everything through VLESS'), _('All traffic of the router and of the LAN devices goes through %s.').format(ev.label(server))));
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

	/* ---------- step 5: review ---------- */

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

		const body = [
			E('p', {}, _('Check the settings. Apply saves them, checks the configuration with sing-box and starts Easy VLESS.')),
			E('h4', {}, _('Server')),
			kv(serverRows(server).concat([
				[ _('Server Test'), t.server ? (t.server.ok ? ev.badge(_('PASS'), 'ok') : ev.badge(_('FAIL'), 'bad')) : E('em', {}, _('not tested')) ]
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

	/* ---------- step 6: apply ---------- */

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

	/* ---------- step 7: done ---------- */

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
					[ _('Routing'), { basic: _('Russian sites direct, everything else through VLESS'), all: _('Everything through VLESS'), keep: _('unchanged') }[st.routing] || '-' ],
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
		const self = this;
		ui.showModal(_('Leave the setup?'), [
			E('p', {}, _('Nothing was applied: Easy VLESS and your settings stay as they are.')),
			imported ? E('p', {}, _('The server "%s" added in this setup is removed again.').format(uci.get(CONFIG, imported, 'remarks') || imported)) : '',
			E('p', { 'class': 'cbi-value-description' }, _('You can open the setup again at any time: Services → Easy VLESS → Setup Wizard.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'id': 'ev-wiz-cancel-no', 'click': ui.hideModal }, _('Continue setup')),
				' ',
				E('button', { 'class': 'btn cbi-button-negative', 'id': 'ev-wiz-cancel-yes', 'click': function() {
					ui.hideModal();
					self.busy = true;
					(imported ? self.dropImported() : Promise.resolve()).then(function() {
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
