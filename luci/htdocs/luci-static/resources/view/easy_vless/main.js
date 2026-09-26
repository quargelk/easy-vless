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
	load: function() {
		return Promise.all([
			uci.load(CONFIG),
			ev.callStatus()
		]);
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
			return E('p', {}, E('em', {}, _('No main node selected.')));

		const byTarget = {};
		rows.forEach(function(r) { (byTarget[r.target] = byTarget[r.target] || []).push(r.entry); });

		return E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Target')),
				E('th', { 'class': 'th' }, _('Used by')),
				E('th', { 'class': 'th' }, _('Server Test')),
				E('th', { 'class': 'th' }, '')
			])
		].concat(Object.keys(byTarget).map(L.bind(function(t) {
			let result, btn = '';
			if (ev.isServer(t)) {
				result = ev.testText(ev.testResults[t]);
				btn = E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleTest', [ t ]) }, _('Test'));
			}
			else if (ev.isGroup(t))
				result = E('em', {}, _('URL Test group: tested by sing-box, see Node List'));
			else
				result = E('em', {}, _('not applicable'));
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, ev.label(t)),
				E('td', { 'class': 'td' }, byTarget[t].join(', ')),
				E('td', { 'class': 'td' }, result),
				E('td', { 'class': 'td right' }, btn)
			]);
		}, this))));
	},

	refreshTests: function() {
		const box = document.getElementById('ev-main-tests');
		if (box)
			dom.content(box, this.renderTests());
	},

	handleTest: function(targets) {
		targets = targets || this.targetRows().map(function(r) { return r.target; }).filter(function(t, i, a) { return ev.isServer(t) && a.indexOf(t) == i; });
		targets.forEach(function(t) { ev.testResults[t] = { pending: true }; });
		this.refreshTests();
		/* one after another: each test starts its own temporary sing-box */
		return targets.reduce(L.bind(function(p, t) {
			return p.then(L.bind(function() {
				return ev.serverTest(t).then(L.bind(this.refreshTests, this));
			}, this));
		}, this), Promise.resolve());
	},

	/* ---------- form ---------- */

	render: function(data) {
		const status = data[1] || {};
		let m, s, o;

		ev.ensureRouter();

		m = this.map = new form.Map(CONFIG);

		s = m.section(form.NamedSection, 'global', 'global', _('Main'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Main switch'),
			_('Save & Apply starts Easy VLESS when on (after a successful sing-box check) and stops it when off.'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'node', _('Node'),
			_('<b>Main Router</b> routes by the rules below (shunt). A server or URL Test group sends all traffic there.'));
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
				return '<em>' + _('No rules yet. Create rules (conditions) in <a href="%s">Rule Manage</a>; their entries then appear here.').format(L.url('admin/services/easy_vless/rules')) + '</em>';
			};
		}

		o = s.option(form.Flag, 'localhost_proxy', _('Localhost Proxy'),
			_('When selected, the router itself is transparently proxied.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'client_proxy', _('Client Proxy'),
			_('When selected, LAN devices are transparently proxied.'));
		o.default = '1';
		o.rmempty = false;

		return m.render().then(L.bind(function(mapEl) {
			poll.add(L.bind(ev.refreshStatus, ev), 5);
			return E('div', {}, [
				E('h2', {}, _('Easy VLESS')),
				E('div', { 'class': 'cbi-map-descr' }, _('VLESS client based on sing-box. Main switch, main node and shunt targets here; servers and URL Test groups in Node List; rule conditions in Rule Manage; DNS and forwarding in Settings.')),
				ev.renderHeader(m, status),
				mapEl,
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('Connection test')),
					E('p', { 'class': 'cbi-value-description' },
						_('Server Test: a temporary sing-box instance with the server\'s VLESS outbound fetches %s over HTTPS (not a TCP connect). It works whether Easy VLESS is running or not; results are for the saved configuration.').format(ev.SERVER_TEST_URL)),
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
