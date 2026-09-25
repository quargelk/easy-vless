'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require poll';
'require dom';
'require easy_vless.common as ev';

/*
 * Easy VLESS - Servers.
 * Server list with per-row actions (make active, URL test, edit, copy VLESS
 * URL, delete) and VLESS URL import. Only fields that util_sing-box.lua
 * really reads, and only transports verified with sing-box-tiny 1.12.22
 * (TCP, WebSocket, gRPC, HTTPUpgrade; TLS, Reality, uTLS), are exposed.
 */

const CONFIG = ev.CONFIG;
const testResults = {};

function stateText(sid) {
	const parts = [];
	const target = ev.activeTarget();
	if (target == sid)
		parts.push(E('strong', { 'style': 'color:#2e7d32' }, '● ' + _('Active')));
	else if (ev.targetUses(target, sid))
		parts.push(E('span', { 'style': 'color:#2e7d32' }, _('in active group')));

	const r = testResults[sid];
	if (r) {
		if (r.pending)
			parts.push(E('em', {}, _('testing…')));
		else if (r.ok)
			parts.push(E('span', {}, _('%d ms').format(r.delay)));
		else
			parts.push(E('span', { 'style': 'color:#c62828', 'title': r.error || '' }, _('failed')));
	}
	if (!parts.length)
		return '-';
	return E('span', {}, parts.reduce(function(acc, p) { return acc.length ? acc.concat([ ' · ', p ]) : [ p ]; }, []));
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(CONFIG),
			ev.callStatus().catch(function() { return {}; })
		]);
	},

	refreshStates: function() {
		ev.servers().forEach(function(s) {
			const el = document.getElementById('ev-state-' + s['.name']);
			if (el)
				dom.content(el, stateText(s['.name']));
		});
	},

	handleMakeActive: function(sid) {
		ev.setActiveTarget(sid);
		return ev.applyIfRunning(this.map).then(L.bind(this.refreshStates, this));
	},

	handleUrlTest: function(sid) {
		testResults[sid] = { pending: true };
		this.refreshStates();
		return ev.callUrltestNode(sid).then(L.bind(function(res) {
			testResults[sid] = res || { ok: false, error: _('No response') };
			this.refreshStates();
		}, this));
	},

	handleImport: function() {
		const textarea = E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width:100%',
			'rows': 6,
			'placeholder': 'vless://uuid@host:443?security=reality&...#Name'
		});

		ui.showModal(_('Import VLESS URL'), [
			E('p', {}, _('One vless:// link per line. Imported servers are saved immediately; unsaved changes on this page are discarded.')),
			textarea,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': ui.createHandlerFn(this, function() {
						const links = textarea.value.trim();
						if (!links)
							return;
						return ev.callImport(links).then(function(res) {
							if (res.code == 0 && res.added > 0) {
								ui.hideModal();
								ui.addNotification(null, E('p', _('%d server(s) imported.').format(res.added)), 'info');
								window.setTimeout(function() { window.location.reload(); }, 1000);
							}
							else {
								ev.showResult(_('Import failed'), false,
									_('No server was imported (unsupported or invalid link, or a transport sing-box does not support).') +
									'\n\n' + (res.output || '') + '\n' + (res.log || ''));
							}
						});
					})
				}, _('Import'))
			])
		]);
	},

	render: function(data) {
		const status = data[1] || {};
		let m, s, o;

		const view_ = this;

		m = this.map = new form.Map(CONFIG, _('Easy VLESS - Servers'),
			_('VLESS servers. "Make active" sends all traffic (or the default traffic, when routing rules are enabled) through the server.'));

		s = m.section(form.GridSection, 'nodes');
		s.addremove = true;
		s.anonymous = true;
		s.sortable = false;
		s.nodescriptions = true;
		s.addbtntitle = _('Add server');
		s.modaltitle = function(section_id) {
			return _('Server') + ' » ' + (uci.get(CONFIG, section_id, 'remarks') || _('New server'));
		};
		s.filter = function(section_id) {
			return ev.isServer(section_id);
		};
		s.handleAdd = function(ev_, name) {
			const section_id = this.map.data.add(CONFIG, this.sectiontype, ev.newName());
			this.map.data.set(CONFIG, section_id, 'protocol', 'vless');
			this.map.data.set(CONFIG, section_id, 'type', 'sing-box');
			this.map.data.set(CONFIG, section_id, 'add_mode', '0');
			this.map.data.set(CONFIG, section_id, 'encryption', 'none');
			/* Runtime-relevant defaults are written explicitly: a Flag whose
			 * value equals its default is otherwise never stored in UCI. */
			this.map.data.set(CONFIG, section_id, 'transport', 'tcp');
			this.map.data.set(CONFIG, section_id, 'tls', '1');
			this.map.addedSection = section_id;
			return this.renderMoreOptionsModal(section_id);
		};
		s.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, [ section_id ]);
			const box = td.lastElementChild;
			box.insertBefore(E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'title': _('Copy VLESS URL'),
				'click': ui.createHandlerFn(ev, 'showVlessUrl', section_id)
			}, _('URL')), box.firstChild);
			box.insertBefore(E('button', {
				'class': 'btn cbi-button',
				'title': _('HTTP test through this server (VLESS): HTTPS request to https://www.gstatic.com/generate_204 via a temporary sing-box instance'),
				'click': ui.createHandlerFn(view_, 'handleUrlTest', section_id)
			}, _('Test')), box.firstChild);
			box.insertBefore(E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'title': _('Use this server'),
				'disabled': (ev.activeTarget() == section_id) ? '' : null,
				'click': ui.createHandlerFn(view_, 'handleMakeActive', section_id)
			}, _('Make active')), box.firstChild);
			return td;
		};
		s.tab('basic', _('Basic'));
		s.tab('transport', _('Transport'));
		s.tab('security', _('TLS / Reality'));

		o = s.taboption('basic', form.Value, 'remarks', _('Name'));
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'address', _('Address'));
		o.datatype = 'host';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'port', _('Port'));
		o.datatype = 'port';
		o.default = '443';
		o.rmempty = false;

		o = s.taboption('basic', form.DummyValue, '_protocol', _('Protocol'));
		o.modalonly = false;
		o.cfgvalue = function() { return 'VLESS'; };

		o = s.taboption('basic', form.Value, 'uuid', _('UUID'));
		o.modalonly = true;
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (!/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(value || ''))
				return _('Expecting a UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)');
			return true;
		};

		o = s.taboption('transport', form.ListValue, 'transport', _('Transport'));
		o.value('tcp', 'TCP');
		o.value('ws', 'WebSocket');
		o.value('grpc', 'gRPC');
		o.value('httpupgrade', 'HTTPUpgrade');
		o.default = 'tcp';
		o.textvalue = function(section_id) {
			const v = this.cfgvalue(section_id) || 'tcp';
			return { raw: 'TCP', tcp: 'TCP', ws: 'WebSocket', grpc: 'gRPC', httpupgrade: 'HTTPUpgrade' }[v] || v;
		};

		o = s.taboption('transport', form.ListValue, 'flow', _('Flow'),
			_('xtls-rprx-vision requires TCP with TLS or Reality.'));
		o.modalonly = true;
		o.value('', _('none'));
		o.value('xtls-rprx-vision', 'xtls-rprx-vision');
		o.depends({ transport: 'tcp', tls: '1' });

		o = s.taboption('transport', form.Value, 'ws_host', _('WebSocket Host'));
		o.modalonly = true;
		o.depends('transport', 'ws');

		o = s.taboption('transport', form.Value, 'ws_path', _('WebSocket path'));
		o.modalonly = true;
		o.placeholder = '/';
		o.depends('transport', 'ws');

		o = s.taboption('transport', form.Value, 'grpc_serviceName', _('gRPC service name'));
		o.modalonly = true;
		o.depends('transport', 'grpc');

		o = s.taboption('transport', form.Value, 'httpupgrade_host', _('HTTPUpgrade Host'));
		o.modalonly = true;
		o.depends('transport', 'httpupgrade');

		o = s.taboption('transport', form.Value, 'httpupgrade_path', _('HTTPUpgrade path'));
		o.modalonly = true;
		o.placeholder = '/';
		o.depends('transport', 'httpupgrade');

		o = s.taboption('security', form.Flag, 'tls', _('TLS'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('security', form.Flag, 'reality', _('Reality'));
		o.depends('tls', '1');

		o = s.taboption('security', form.Value, 'tls_serverName', _('Server name (SNI)'));
		o.modalonly = true;
		o.datatype = 'hostname';
		o.depends('tls', '1');

		o = s.taboption('security', form.Value, 'reality_publicKey', _('Reality public key'));
		o.modalonly = true;
		o.depends('reality', '1');
		o.validate = function(section_id, value) {
			if (!/^[A-Za-z0-9_-]{43}$/.test(value || ''))
				return _('Expecting a 43-character base64url X25519 public key');
			return true;
		};

		o = s.taboption('security', form.Value, 'reality_shortId', _('Reality short ID'));
		o.modalonly = true;
		o.depends('reality', '1');
		o.validate = function(section_id, value) {
			if (value && !/^([0-9a-fA-F]{2}){1,8}$/.test(value))
				return _('Expecting an even number of hexadecimal characters (at most 16)');
			return true;
		};

		o = s.taboption('security', form.Flag, 'utls', _('uTLS fingerprint'),
			_('Always enabled for Reality.'));
		o.modalonly = true;
		o.depends({ tls: '1', reality: '0' });

		o = s.taboption('security', form.ListValue, 'fingerprint', _('Fingerprint'));
		o.modalonly = true;
		[ 'chrome', 'firefox', 'safari', 'edge', 'ios', 'android', 'random', 'randomized' ].forEach(function(fp) {
			o.value(fp);
		});
		o.default = 'chrome';
		o.depends('reality', '1');
		o.depends('utls', '1');

		o = s.taboption('security', form.Flag, 'tls_allowInsecure', _('Allow insecure'),
			_('Do not verify the server certificate. Not recommended.'));
		o.modalonly = true;
		o.depends({ tls: '1', reality: '0' });

		o = s.taboption('basic', form.DummyValue, '_state', _('Status'));
		o.modalonly = false;
		o.rawhtml = true;
		o.textvalue = function(section_id) {
			return E('span', { 'id': 'ev-state-' + section_id }, stateText(section_id));
		};

		return m.render().then(L.bind(function(mapEl) {
			poll.add(L.bind(ev.refreshStatus, ev), 5);
			return E('div', {}, [
				ev.renderHeader(m, status, [
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-add',
						'click': ui.createHandlerFn(this, 'handleImport')
					}, _('Import VLESS URL'))
				]),
				mapEl
			]);
		}, this));
	}
});
