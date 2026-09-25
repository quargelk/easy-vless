'use strict';
'require baseclass';
'require rpc';
'require uci';
'require ui';
'require dom';

/*
 * Easy VLESS - helpers shared by the LuCI views (servers, urltest, rules).
 *
 * UCI model (the existing easy-vless runtime schema, PassWall2-derived):
 *   easy_vless.global.node          what the runtime starts: a server, a URL
 *                                   Test group, or the routing-rules router
 *   config nodes, protocol=vless    a VLESS server
 *   config nodes, protocol=_urltest a URL Test group (list urltest_node)
 *   config nodes 'main_router',     the routing rules ("_shunt" node):
 *     protocol=_shunt                 default_node = default outbound,
 *                                     option <rule id> = target of that rule
 *   config shunt_rules              one rule (domain_list, ip_list, ...)
 *
 * "Active target" = default outbound: global.node, or main_router.default_node
 * while routing rules are enabled (global.node == 'main_router').
 */

const CONFIG = 'easy_vless';
const ROUTER = 'main_router';

const callStatus = rpc.declare({ object: 'luci.easy_vless', method: 'status', expect: { '': {} } });
const callCheck = rpc.declare({ object: 'luci.easy_vless', method: 'check', params: [ 'node' ], expect: { '': {} } });
const callStart = rpc.declare({ object: 'luci.easy_vless', method: 'start', expect: { '': {} } });
const callStop = rpc.declare({ object: 'luci.easy_vless', method: 'stop', expect: { '': {} } });
const callImport = rpc.declare({ object: 'luci.easy_vless', method: 'import', params: [ 'links' ], expect: { '': {} } });
const callUrltestNode = rpc.declare({ object: 'luci.easy_vless', method: 'urltest_node', params: [ 'node' ], expect: { '': {} } });
const callGroups = rpc.declare({ object: 'luci.easy_vless', method: 'groups', expect: { '': {} } });
const callGroupTest = rpc.declare({ object: 'luci.easy_vless', method: 'group_test', params: [ 'group' ], expect: { '': {} } });
const callUciCommit = rpc.declare({ object: 'uci', method: 'commit', params: [ 'config' ] });

function sleep(ms) {
	return new Promise(function(resolve) { window.setTimeout(resolve, ms); });
}

return baseclass.extend({
	CONFIG: CONFIG,
	ROUTER: ROUTER,

	callStatus: callStatus,
	callCheck: callCheck,
	callImport: callImport,
	callUrltestNode: callUrltestNode,
	callGroups: callGroups,
	callGroupTest: callGroupTest,

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

	/* Random section name, so rows can be referenced (active target, rule
	 * targets) before the first save. */
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
			return _('Direct (no proxy)');
		if (sid == '_blackhole')
			return _('Block');
		if (sid == '_default')
			return _('Default outbound');
		const remarks = uci.get(CONFIG, sid, 'remarks');
		if (this.isGroup(sid))
			return _('URL Test group') + ': ' + (remarks || sid);
		if (this.isServer(sid))
			return '%s (%s:%s)'.format(remarks || sid, uci.get(CONFIG, sid, 'address') || '?', uci.get(CONFIG, sid, 'port') || '?');
		if (sid == ROUTER)
			return _('Routing rules');
		return remarks || sid;
	},

	/* Values for "outbound" selects: servers and URL Test groups. */
	addTargetValues: function(o, withDirect) {
		if (withDirect)
			o.value('_direct', _('Direct (no proxy)'));
		this.servers().forEach(L.bind(function(s) { o.value(s['.name'], this.label(s['.name'])); }, this));
		this.groups().forEach(L.bind(function(s) { o.value(s['.name'], this.label(s['.name'])); }, this));
	},

	rulesEnabled: function() {
		return uci.get(CONFIG, 'global', 'node') == ROUTER;
	},

	ensureRouter: function() {
		if (!uci.get(CONFIG, ROUTER)) {
			uci.add(CONFIG, 'nodes', ROUTER);
			uci.set(CONFIG, ROUTER, 'remarks', 'Routing rules');
			uci.set(CONFIG, ROUTER, 'type', 'sing-box');
			uci.set(CONFIG, ROUTER, 'protocol', '_shunt');
		}
	},

	activeTarget: function() {
		const node = uci.get(CONFIG, 'global', 'node');
		if (node == ROUTER)
			return uci.get(CONFIG, ROUTER, 'default_node') || '_direct';
		return node || '';
	},

	setActiveTarget: function(sid) {
		if (this.rulesEnabled())
			uci.set(CONFIG, ROUTER, 'default_node', sid);
		else
			uci.set(CONFIG, 'global', 'node', sid);
	},

	setRulesEnabled: function(enabled) {
		const target = this.activeTarget();
		if (enabled) {
			this.ensureRouter();
			uci.set(CONFIG, ROUTER, 'default_node', target || '_direct');
			uci.set(CONFIG, 'global', 'node', ROUTER);
		}
		else if (this.rulesEnabled()) {
			uci.set(CONFIG, 'global', 'node', (target && target != '_direct') ? target : '');
		}
	},

	/* Is a server used by the running configuration (directly or via a group)? */
	targetUses: function(target, sid) {
		if (!target)
			return false;
		if (target == sid)
			return true;
		if (this.isGroup(target))
			return L.toArray(uci.get(CONFIG, target, 'urltest_node')).indexOf(sid) > -1;
		return false;
	},

	/* ---------- saving / service control ---------- */

	/* Save the form to UCI and commit easy_vless: the runtime only reads the
	 * committed configuration. */
	saveAndCommit: function(map) {
		return map.save(null, true).catch(function(e) {
			ui.addNotification(null, E('p', _('The form contains invalid values, nothing was saved: %s').format(e.message || e)), 'error');
			throw e;
		}).then(function() {
			return uci.save();
		}).then(function() {
			return callUciCommit(CONFIG);
		}).then(function() {
			return ui.changes.init();
		});
	},

	showResult: function(title, ok, text) {
		ui.showModal(title, [
			E('p', {}, E('strong', {}, ok ? _('Success.') : _('Failed.'))),
			text ? E('pre', { 'style': 'white-space:pre-wrap;max-height:25em;overflow:auto' }, text) : '',
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
			])
		]);
	},

	handleCheck: function(map) {
		return this.saveAndCommit(map).then(function() {
			return callCheck('');
		}).then(L.bind(function(res) {
			this.showResult(_('Configuration check'), res.code == 0, res.output);
		}, this));
	},

	/* Validate (sing-box check) first; only then enable and (re)start. */
	handleStart: function(map) {
		return this.saveAndCommit(map).then(function() {
			return callStart();
		}).then(L.bind(function(res) {
			if (res.code != 0)
				return this.showResult(_('Not started: configuration check failed'), false, res.output);
			ui.addNotification(null, E('p', _('Easy VLESS is (re)starting with the saved configuration…')), 'info');
			return sleep(4000).then(L.bind(this.refreshStatus, this));
		}, this));
	},

	handleStop: function() {
		return callStop().then(L.bind(function() {
			ui.addNotification(null, E('p', _('Easy VLESS is stopping…')), 'info');
			return sleep(3000).then(L.bind(this.refreshStatus, this));
		}, this));
	},

	/* Apply a changed active target: restart only if the service is running. */
	applyIfRunning: function(map) {
		return this.saveAndCommit(map).then(function() {
			return callStatus();
		}).then(L.bind(function(st) {
			if (st.running)
				return this.handleStart(map);
			ui.addNotification(null, E('p', _('Saved. Easy VLESS is stopped; the change applies on the next start.')), 'info');
		}, this));
	},

	/* ---------- status ---------- */

	lastStatus: {},

	renderStatus: function(st) {
		const running = !!st.running;
		const node = st.node;
		let target = node ? this.label(node) : _('none selected');
		if (node == ROUTER)
			target = _('Routing rules, default: %s').format(this.label(uci.get(CONFIG, ROUTER, 'default_node') || '_direct'));

		const rows = [
			[ _('Service'), running
				? E('strong', { 'style': 'color:#2e7d32' }, _('Running') + (st.pid ? ' (PID %s)'.format(st.pid) : ''))
				: E('strong', { 'style': 'color:#c62828' }, _('Stopped')) ],
			[ _('Main switch'), st.enabled ? _('Enabled (starts on boot)') : _('Disabled') ],
			[ _('Active'), target ],
			[ _('Memory (sing-box)'), running && st.rss_kb
				? _('%s MiB (peak %s MiB)').format((st.rss_kb / 1024).toFixed(1), ((st.rss_peak_kb || 0) / 1024).toFixed(1)) : '-' ],
			[ _('Firewall'), st.nft_table ? _('nft table inet easy_vless present') : _('no Easy VLESS rules') ],
			[ _('sing-box'), st.singbox_version
				? '%s (%s)%s'.format(st.singbox_version, st.singbox_bin || '-',
					st.singbox_backend ? '' : ' - ' + _('easy-vless-sing-box is not installed'))
				: _('not found (requires sing-box >= %s)').format(st.singbox_min_version || '1.12.0') ]
		];

		return E('div', {}, [
			E('table', { 'class': 'table' }, rows.map(function(r) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'style': 'width:33%' }, r[0]),
					E('td', { 'class': 'td left' }, r[1])
				]);
			})),
			E('details', {}, [
				E('summary', {}, _('Recent log')),
				E('pre', { 'style': 'white-space:pre-wrap;max-height:20em;overflow:auto' }, st.log || _('(empty)'))
			])
		]);
	},

	refreshStatus: function() {
		return callStatus().then(L.bind(function(st) {
			this.lastStatus = st;
			const box = document.getElementById('easy-vless-status');
			if (box)
				dom.content(box, this.renderStatus(st));
			return st;
		}, this));
	},

	/* Status box + service buttons, shown on top of every page. */
	renderHeader: function(map, st, extraButtons) {
		this.lastStatus = st || {};
		const buttons = [
			E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, 'handleStart', map) }, _('Apply & Start')),
			' ',
			E('button', { 'class': 'btn cbi-button cbi-button-reset', 'click': ui.createHandlerFn(this, 'handleStop') }, _('Stop')),
			' ',
			E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleCheck', map) }, _('Check config'))
		].concat(extraButtons || []);

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Status')),
			E('div', { 'id': 'easy-vless-status' }, this.renderStatus(this.lastStatus)),
			E('div', { 'style': 'margin:1em 0' }, buttons)
		]);
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
		case 'mkcp':
			type = 'kcp';
			add('headerType', g('mkcp_guise'));
			add('seed', g('mkcp_seed'));
			break;
		case 'xhttp':
			add('host', g('xhttp_host'));
			add('path', g('xhttp_path'));
			add('mode', g('xhttp_mode'));
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

	showVlessUrl: function(sid) {
		const r = this.buildVlessUrl(sid);
		const field = E('textarea', { 'class': 'cbi-input-textarea', 'style': 'width:100%', 'rows': 4, 'readonly': 'readonly' }, r.url || '');
		const note = E('span', { 'style': 'margin-left:1em' });

		ui.showModal(_('VLESS URL') + ' » ' + (uci.get(CONFIG, sid, 'remarks') || sid), [
			field,
			r.warnings.length ? E('div', { 'class': 'alert-message warning' }, [
				E('p', {}, _('Not included in the URL:')),
				E('ul', {}, r.warnings.map(function(w) { return E('li', {}, w); }))
			]) : '',
			E('p', { 'class': 'cbi-value-description' }, _('Generated from the saved settings; unsaved edits are not included.')),
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
	}
});
