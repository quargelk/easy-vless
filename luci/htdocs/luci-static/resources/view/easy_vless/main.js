'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require poll';
'require dom';
'require easy_vless.common as ev';

/*
 * Easy VLESS - Main (PassWall2 "Basic Settings -> Main" model).
 * Status, main switch, main node and - when the main node is the Main Router
 * (the "_shunt" node) - the shunt entries: one target per rule from Rule
 * Manage plus Default. Targets are stored in the existing UCI model
 * (main_router.<rule id>, main_router.default_node).
 */

const CONFIG = ev.CONFIG;
const ROUTER = ev.ROUTER;

return view.extend({
	/* A new, not yet configured installation opens the First Run Wizard
	 * (rpcd wizard_state: never completed, main switch off, no node
	 * selected) - unless it was left with "Leave setup" in this session. */
	load: function() {
		return ev.callWizardState().then(function(ws) {
			if (ws.needed && !ws.rpc_error && !ev.wizardDismissed()) {
				window.location.replace(L.url('admin/services/easy_vless/wizard'));
				return new Promise(function() {});
			}
			return Promise.all([
				uci.load(CONFIG),
				ev.callStatus(),
				ws,
				ev.refreshTests()
			]);
		});
	},

	/* ---------- connection tests (Server Test of the Main Router targets) ---------- */

	/* Entries using each target: [{ label, target }] in shunt order. */
	targetRows: function() {
		const node = uci.get(CONFIG, 'global', 'node');
		const rows = [];
		if (node == ROUTER) {
			ev.rules().forEach(function(r) {
				const t = uci.get(CONFIG, ROUTER, r['.name']);
				if (t)
					rows.push({ entry: r.remarks || r['.name'], target: t == '_default' ? (uci.get(CONFIG, ROUTER, 'default_node') || '_direct') : t });
			});
			rows.push({ entry: _('Default'), target: uci.get(CONFIG, ROUTER, 'default_node') || '_direct' });
		}
		else if (node) {
			rows.push({ entry: _('Main node'), target: node });
		}
		return rows;
	},

	renderTests: function() {
		const rows = this.targetRows();
		if (!rows.length)
			return E('p', {}, E('em', {}, _('No node selected yet: choose one above in Node, or add a server in Node List.')));

		const byTarget = {};
		rows.forEach(function(r) { (byTarget[r.target] = byTarget[r.target] || []).push(r.entry); });

		const th = function(t) { return E('th', { 'class': 'th' }, t); };
		return E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				th(_('Target', 'routing target')), th(_('Used by')), th(_('Result')), th(_('Latency')), th(_('Response / error')), th('')
			])
		].concat(Object.keys(byTarget).map(L.bind(function(t) {
			let result = '-', latency = '-', detail = '', btn = '';
			if (ev.isServer(t)) {
				const info = ev.testInfo(t, 'server');
				const r = info.result;
				btn = ev.smallButton(_('Test'), _('Server Test of this server'), 'ev-test-btn', ui.createHandlerFn(this, 'handleTest', [ t ]));
				btn.disabled = info.state == 'testing' || info.state == 'queued';
				if (info.state == 'testing')
					result = E('span', { 'style': 'white-space:nowrap' }, [ E('span', { 'class': 'spinning', 'style': 'display:inline-block;width:1em' }, ' '), ' ', _('Testing…') ]);
				else if (info.state == 'queued')
					result = E('em', {}, _('Queued'));
				else if (r && r.ok)
					result = ev.badge(_('PASS'), 'ok');
				else if (r)
					result = ev.badge(_('FAIL'), 'bad');
				if (r && r.ok) {
					latency = _('%d ms').format(r.delay);
					detail = E('span', {}, [ 'HTTP ' + (r.http_code || ''), ' · ', E('small', { 'style': 'opacity:.75' }, ev.agoText(r.time)) ]);
				}
				else if (r)
					detail = E('span', {}, [ ev.testError(r), ' · ', E('small', { 'style': 'opacity:.75' }, ev.agoText(r.time)) ]);
				else
					detail = E('em', {}, _('not tested'));
			}
			else if (ev.isGroup(t))
				detail = E('em', {}, _('URL Test group: sing-box tests its servers itself (Node List → URL Test)'));
			else
				detail = E('em', {}, _('not applicable'));
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, ev.label(t)),
				E('td', { 'class': 'td' }, byTarget[t].join(', ')),
				E('td', { 'class': 'td' }, result),
				E('td', { 'class': 'td' }, latency),
				E('td', { 'class': 'td' }, detail),
				E('td', { 'class': 'td right' }, btn)
			]);
		}, this))));
	},

	refreshTests: function() {
		const box = document.getElementById('ev-main-tests');
		if (box)
			dom.content(box, this.renderTests());
	},

	/* Queued on the router (one test at a time; a server that is already
	 * queued or being tested is not tested twice); the table follows the
	 * test state. */
	handleTest: function(targets) {
		targets = targets || this.targetRows().map(function(r) { return r.target; }).filter(function(t, i, a) { return ev.isServer(t) && a.indexOf(t) == i; });
		return ev.queueTests('server', targets.filter(function(t) { return !ev.testBusy(t, 'server'); }));
	},

	/* ---------- form ---------- */

	render: function(data) {
		const status = data[1] || {};
		const wstate = data[2] || {};
		let m, s, o;

		ev.ensureRouter();

		m = this.map = new form.Map(CONFIG);

		s = m.section(form.NamedSection, 'global', 'global', _('Main'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Main switch'),
			_('On: Save & Apply checks the configuration with sing-box and starts Easy VLESS (also after every reboot). Off: Save & Apply stops it.'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'node', _('Node'),
			_('Where the traffic goes. <b>Main Router</b>: by the rules of Rule Manage - each rule gets a target below, everything else goes to Default. A server or a URL Test group: all traffic goes to it.'));
		o.value('', _('-- select --'));
		o.value(ROUTER, _('Main Router (shunt)'));
		ev.servers().forEach(function(srv) { o.value(srv['.name'], ev.label(srv['.name'])); });
		ev.groups().forEach(function(g) { o.value(g['.name'], ev.label(g['.name'])); });
		o.rmempty = true;

		/* Shunt entries: one per rule (Rule Manage order) + Default. The
		 * values live in main_router; hidden entries must not be removed. */
		const rules = ev.rules();
		rules.forEach(function(r) {
			const rid = r['.name'];
			o = s.option(form.ListValue, '_shunt_' + rid, '* ' + (r.remarks || rid));
			o.depends('node', ROUTER);
			o.value('', _('Not used (rule off)'));
			ev.addTargetValues(o, true);
			o.cfgvalue = function() { return uci.get(CONFIG, ROUTER, rid) || ''; };
			o.write = function(section_id, value) { uci.set(CONFIG, ROUTER, rid, value); };
			o.remove = function(section_id) {
				/* called for '' (Not used) and when hidden: only unset for an
				 * explicit "Not used" while the Main Router is selected. */
				if (this.isActive(section_id))
					uci.unset(CONFIG, ROUTER, rid);
			};
		});

		o = s.option(form.ListValue, '_shunt_default', '* ' + _('Default'),
			_('Traffic that matches no rule above.'));
		o.depends('node', ROUTER);
		ev.addTargetValues(o, false);
		o.cfgvalue = function() { return uci.get(CONFIG, ROUTER, 'default_node') || '_direct'; };
		o.write = function(section_id, value) { uci.set(CONFIG, ROUTER, 'default_node', value); };
		o.remove = function() {};

		if (!rules.length) {
			o = s.option(form.DummyValue, '_no_rules', ' ');
			o.depends('node', ROUTER);
			o.rawhtml = true;
			o.cfgvalue = function() {
				return '<em>' + _('No rules yet. Create rules in <a href="%s">Rule Manage</a> (the prepared RUSSIA / PROXY / QUIC / UDP rules are added there with one click); each rule then gets a target here.').format(L.url('admin/services/easy_vless/rules')) + '</em>';
			};
		}

		o = s.option(form.Flag, 'localhost_proxy', _('Localhost Proxy'),
			_('Traffic of the router itself (opkg, curl, ...) also goes through Easy VLESS routing.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'client_proxy', _('Client Proxy'),
			_('Traffic of LAN devices is transparently redirected (TPROXY) into Easy VLESS routing. Off: LAN devices bypass Easy VLESS.'));
		o.default = '1';
		o.rmempty = false;

		return m.render().then(L.bind(function(mapEl) {
			poll.add(L.bind(ev.refreshStatus, ev), 5);
			poll.add(L.bind(ev.refreshTests, ev), 10);
			ev.onTestUpdate(L.bind(this.refreshTests, this));
			/* update notice (0.9.0): asked after the page is there - the router
			 * answers from its cache, or asks GitHub once a day; never installs */
			if (ev.updateCheckEnabled())
				ev.callUpdate('check').then(function(res) {
					const slot = document.getElementById('ev-update-slot');
					const notice = ev.updateNotice(res);
					if (slot && notice)
						dom.content(slot, notice);
				});
			return E('div', { 'class': 'ev-page' }, [
				ev.pageStyle(),
				E('h2', {}, _('Easy VLESS')),
				E('div', { 'class': 'cbi-map-descr' }, _('Easy VLESS sends the traffic of the router and of your LAN devices through a VLESS server (sing-box). Here: service status, the main switch and where the traffic goes. Servers and subscriptions are in Node List, routing rules in Rule Manage, DNS and forwarding in Settings.')),
				wstate.needed ? E('div', { 'class': 'alert-message warning', 'id': 'ev-setup-note' }, [
					E('p', {}, _('Easy VLESS is not set up yet. The setup wizard adds your VLESS server, tests it, sets up the routing and starts Easy VLESS.')),
					E('a', { 'class': 'btn cbi-button cbi-button-action', 'href': L.url('admin/services/easy_vless/wizard'),
						'click': function() { ev.setWizardDismissed(false); } }, _('Start setup wizard'))
				]) : '',
				E('div', { 'id': 'ev-update-slot' }),
				ev.renderHeader(m, status, null, false, true),
				mapEl,
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('Connection test')),
					E('p', { 'class': 'cbi-value-description' },
						_('Server Test opens %s over HTTPS through the server (a real request through a temporary sing-box instance, not only a TCP connect). It works whether Easy VLESS is running or not and uses the saved server settings.').format(ev.SERVER_TEST_URL)),
					E('div', { 'id': 'ev-main-tests' }, this.renderTests()),
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'handleTest', null) }, _('Test all targets'))
				])
			]);
		}, this));
	},

	handleSave: function() {
		return ev.handleSave(this.map);
	},

	handleSaveApply: function() {
		return ev.handleApply(this.map);
	}
});
