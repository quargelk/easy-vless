'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require poll';
'require dom';
'require easy_vless.common as ev';

/*
 * Easy VLESS - Node List (PassWall2 "Node List" + "Node Subscribe" model).
 *   Servers: VLESS nodes with Use / Test / URL (copy, QR) / Up / Down /
 *            Edit / Delete, Add and Import VLESS URL.
 *   URL Test: sing-box "urltest" groups (util_sing-box.lua
 *            gen_urltest_outbound) with live results from the Clash API of
 *            the running sing-box; default test URL https://x.com.
 *   Subscriptions: subscribe_list sections handled by subscribe.lua
 *            (VLESS nodes only; other types are skipped and counted).
 * Only fields that util_sing-box.lua really reads, and only transports
 * verified with sing-box-tiny 1.12.22 (TCP, WebSocket, gRPC, HTTPUpgrade;
 * TLS, Reality, uTLS), are exposed.
 */

const CONFIG = ev.CONFIG;
let liveGroups = null;      /* Clash API /proxies (groups with members) */
let liveError = null;
let lastGroupTest = {};     /* member tag -> result of the last manual group test */

function stateText(sid) {
	const parts = [];
	const target = ev.activeTarget();
	if (uci.get(CONFIG, 'global', 'node') == sid || target == sid)
		parts.push(ev.badge(_('Active'), 'ok'));
	else if (ev.targetUses(target, sid))
		parts.push(ev.badge(_('in active group'), 'ok'));
	else if (ev.references(sid).length)
		parts.push(E('span', { 'title': ev.references(sid).join(', ') }, _('in use')));
	if (!parts.length)
		return '-';
	return E('span', {}, parts);
}

/* URL Test column: last delay sing-box measured for this server in a running
 * URL Test group (https://x.com by default); 0 = failed. */
function urltestText(sid) {
	if (!liveGroups)
		return E('span', { 'title': liveError || '' }, '-');
	let best = null;
	liveGroups.forEach(function(g) {
		(g.members || []).forEach(function(m) {
			if (m.id == sid && m.delay != null && (best == null || (m.delay > 0 && (best == 0 || m.delay < best))))
				best = m.delay;
		});
	});
	if (best == null)
		return '-';
	return best > 0 ? _('%d ms').format(best) : E('span', { 'style': 'color:#c62828' }, _('failed'));
}

function groupDelayText(d, tested) {
	if (d == null && tested && tested.error)
		return E('span', { 'style': 'color:#c62828', 'title': tested.error }, _('failed'));
	if (d == null)
		return E('em', {}, _('no result (not tested yet or unreachable)'));
	if (d == 0)
		return E('span', { 'style': 'color:#c62828' }, _('failed'));
	return _('%d ms').format(d);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(CONFIG),
			ev.callStatus(),
			ev.callGroups()
		]);
	},

	setGroups: function(res) {
		if (res && res.ok) {
			liveGroups = res.groups || [];
			liveError = null;
		}
		else {
			liveGroups = null;
			liveError = (res && res.error) || _('No data');
		}
	},

	refreshRows: function() {
		ev.servers().forEach(function(s) {
			const sid = s['.name'];
			let el = document.getElementById('ev-state-' + sid);
			if (el) dom.content(el, stateText(sid));
			el = document.getElementById('ev-test-' + sid);
			if (el) dom.content(el, ev.testText(ev.testResults[sid]));
			el = document.getElementById('ev-ut-' + sid);
			if (el) dom.content(el, urltestText(sid));
		});
		const box = document.getElementById('ev-urltest-results');
		if (box)
			dom.content(box, this.renderGroupResults());
	},

	refreshLive: function() {
		return ev.callGroups().then(L.bind(function(res) {
			this.setGroups(res);
			this.refreshRows();
		}, this));
	},

	/* ---------- server actions ---------- */

	handleUse: function(sid) {
		ev.setActiveTarget(sid);
		return ev.applyIfRunning(this.map).then(L.bind(this.refreshRows, this));
	},

	handleTest: function(sid) {
		ev.testResults[sid] = { pending: true };
		this.refreshRows();
		return ev.serverTest(sid).then(L.bind(this.refreshRows, this));
	},

	handleTestAll: function() {
		const ids = ev.servers().map(function(s) { return s['.name']; });
		ids.forEach(function(sid) { ev.testResults[sid] = { pending: true }; });
		this.refreshRows();
		return ids.reduce(L.bind(function(p, sid) {
			return p.then(L.bind(function() { return ev.serverTest(sid).then(L.bind(this.refreshRows, this)); }, this));
		}, this), Promise.resolve());
	},

	handleMove: function(sid, up) {
		if (!ev.moveSection(sid, up, function(s) { return s.protocol == 'vless'; }))
			return Promise.resolve();
		return ev.saveAndCommit(this.map).catch(function() {});
	},

	handleImport: function() {
		const textarea = E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width:100%',
			'rows': 8,
			'placeholder': 'vless://uuid@host:443?security=reality&...#Name'
		});

		ui.showModal(_('Import VLESS URL'), [
			E('p', {}, _('One vless:// link per line (bulk import supported). Imported servers are added to the list; existing servers are kept. Unsaved changes on this page are discarded.')),
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
						ev.showBusy(_('Import VLESS URL'), _('Parsing links…'));
						return ev.callImport(links).then(function(res) {
							const summary = _('Links found: %d · imported: %d · skipped: %d').format(res.found || 0, res.added || 0, res.skipped || 0);
							const details = [ res.output, res.log ].filter(function(x) { return x; }).join('\n');
							if (res.added > 0) {
								ev.showResult(_('Import VLESS URL'), res.skipped ? 'warn' : 'ok', summary, details);
								const btn = document.querySelector('.modal .btn');
								if (btn)
									btn.addEventListener('click', function() { window.location.reload(); });
							}
							else {
								ev.showResult(_('Import VLESS URL'), 'bad', summary, (details || '') + '\n' +
									_('No server was imported (unsupported or invalid link, or a transport sing-box does not support).'));
							}
						});
					})
				}, _('Import'))
			])
		]);
	},

	/* ---------- subscriptions ---------- */

	handleSubscribe: function(id) {
		ev.showBusy(_('Subscription'), _('Downloading and parsing the subscription…'));
		return ev.callSubscribe('update', id || 'all').then(function(res) {
			if (res.code !== 0)
				return ev.showResult(_('Subscription'), 'bad', res.output || res.error || _('Failed'));
			const mark = res.log_mark || 0, before = res.nodes || 0;
			return ev.waitFor(function(st, sawBusy, elapsed) {
				if (st.subscribe_busy)
					return null;
				return (elapsed > 3000) ? true : null;
			}, 120000, mark).then(function(r) {
				const log = (r.status && r.status.log) || '';
				uci.unload(CONFIG);
				return uci.load(CONFIG).then(function() {
					const now = uci.sections(CONFIG, 'nodes').length;
					ev.showResult(_('Subscription'), r.done ? 'ok' : 'warn',
						r.done ? _('Subscription update finished: %d nodes before, %d now.').format(before, now) : _('Still running, check the log later.'),
						log);
					const btn = document.querySelector('.modal .btn');
					if (btn)
						btn.addEventListener('click', function() { window.location.reload(); });
				});
			});
		});
	},

	handleTruncate: function(id) {
		return ev.callSubscribe('truncate', id).then(function(res) {
			if (res.code !== 0)
				return ev.showResult(_('Subscription'), 'bad', res.output || res.error || _('Failed'));
			ev.showResult(_('Subscription'), 'ok', _('%d subscribed nodes deleted.').format(res.removed || 0));
			const btn = document.querySelector('.modal .btn');
			if (btn)
				btn.addEventListener('click', function() { window.location.reload(); });
		});
	},

	/* ---------- URL Test groups ---------- */

	renderGroupResults: function() {
		const groups = ev.groups();
		if (!groups.length)
			return E('p', {}, E('em', {}, _('No URL Test groups yet.')));

		if (!liveGroups)
			return E('div', { 'class': 'alert-message' }, [
				E('p', {}, _('No live results: %s').format(liveError || '')),
				E('p', {}, _('Results come from the running sing-box (Clash API). Use a group as main node, Default or rule target and start Easy VLESS.'))
			]);

		return E('div', {}, groups.map(L.bind(function(g) {
			const id = g['.name'];
			const live = liveGroups.filter(function(x) { return x.id == id; })[0];
			const title = E('h4', {}, [ g.remarks || id, ' ', E('small', { 'style': 'opacity:.7' }, g.urltest_url || ev.URL_TEST_URL) ]);
			if (!live)
				return E('div', {}, [ title, E('p', {}, E('em', {}, _('Not part of the running configuration.'))) ]);

			return E('div', {}, [
				title,
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Server')),
						E('th', { 'class': 'th' }, _('Latency')),
						E('th', { 'class': 'th' }, _('Selected by sing-box')),
						E('th', { 'class': 'th' }, '')
					])
				].concat(live.members.map(L.bind(function(mem) {
					return E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, mem.id ? (uci.get(CONFIG, mem.id, 'remarks') || mem.id) : mem.tag),
						E('td', { 'class': 'td' }, groupDelayText(mem.delay, lastGroupTest[mem.tag])),
						E('td', { 'class': 'td' }, (live.now == mem.tag) ? ev.badge(_('selected'), 'ok') : ''),
						E('td', { 'class': 'td right' }, mem.id ? E('button', {
							'class': 'btn cbi-button',
							'title': _('Stop using the group and use this server'),
							'click': ui.createHandlerFn(this, 'handleUse', mem.id)
						}, _('Use this server')) : '')
					]);
				}, this)))),
				E('div', {}, E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleGroupTest', id)
				}, _('Test all servers now')))
			]);
		}, this)));
	},

	handleGroupTest: function(id) {
		return ev.callGroupTest(id).then(L.bind(function(res) {
			if (!res.ok) {
				ev.showResult(_('URL Test'), 'bad', res.error || _('Failed'));
				return;
			}
			this.setGroups(res);
			lastGroupTest = {};
			L.toArray(res.tested).forEach(function(t) { lastGroupTest[t.tag] = t; });
			this.refreshRows();
		}, this));
	},

	/* Live URL Test results right below the URL Test groups section. */
	placeLive: function(mapEl) {
		const live = E('div', { 'class': 'cbi-section' }, [
			E('h4', {}, _('URL Test live results')),
			E('div', { 'id': 'ev-urltest-results' }, this.renderGroupResults())
		]);
		const sections = mapEl.querySelectorAll('.cbi-section');
		let anchor = null;
		sections.forEach(function(sec) {
			const h = sec.querySelector('h3');
			if (h && h.textContent == _('URL Test'))
				anchor = sec;
		});
		if (anchor)
			anchor.parentNode.insertBefore(live, anchor.nextSibling);
		else
			mapEl.appendChild(live);
		return mapEl;
	},

	/* ---------- render ---------- */

	render: function(data) {
		const status = data[1] || {};
		this.setGroups(data[2]);
		let m, s, o;
		const view_ = this;

		m = this.map = new form.Map(CONFIG);

		/* ===== Servers ===== */
		s = m.section(form.GridSection, 'nodes', _('Servers'),
			_('"Use" makes the server the main node (or the Default target while the Main Router is the main node). "Test" = Server Test (%s through the server). "URL Test" = last latency measured by a running URL Test group.').format(ev.SERVER_TEST_URL));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = false;
		s.nodescriptions = true;
		s.addbtntitle = _('Add server');
		s.modaltitle = function(section_id) {
			return _('Node Config') + ' » ' + (uci.get(CONFIG, section_id, 'remarks') || _('New server'));
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
		s.handleRemove = function(section_id, ev_) {
			const refs = ev.references(section_id);
			if (refs.length) {
				ev.showResult(_('Delete server'), 'bad', _('This server is still used and was not deleted.'),
					_('Used by:') + '\n' + refs.join('\n') + '\n\n' + _('Select another target there first.'));
				return Promise.resolve();
			}
			return form.GridSection.prototype.handleRemove.apply(this, [ section_id, ev_ ]);
		};
		s.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, [ section_id ]);
			const box = td.lastElementChild;
			const btn = function(label, cls, title, fn, args) {
				return E('button', { 'class': 'btn cbi-button ' + (cls || ''), 'title': title || '', 'click': ui.createHandlerFn.apply(ui, [ view_, fn ].concat(args)) }, label);
			};
			[
				btn(_('Use'), 'cbi-button-apply', _('Use this server'), 'handleUse', [ section_id ]),
				btn(_('Test'), '', _('Server Test: HTTPS request to %s through this server (temporary sing-box instance)').format(ev.SERVER_TEST_URL), 'handleTest', [ section_id ]),
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'title': _('VLESS URL: copy / QR code'), 'click': ui.createHandlerFn(ev, 'showVlessUrl', section_id) }, _('URL')),
				btn('↑', '', _('Up'), 'handleMove', [ section_id, true ]),
				btn('↓', '', _('Down'), 'handleMove', [ section_id, false ])
			].reverse().forEach(function(b) { box.insertBefore(b, box.firstChild); });
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

		o = s.taboption('basic', form.Value, 'uuid', _('UUID'));
		o.modalonly = true;
		o.rmempty = false;
		o.password = true;
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
		o.modalonly = true;
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('security', form.Flag, 'reality', _('Reality'));
		o.modalonly = true;
		o.depends('tls', '1');

		o = s.taboption('security', form.DummyValue, '_security', _('Security'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			if (uci.get(CONFIG, section_id, 'tls') != '1')
				return _('none');
			return uci.get(CONFIG, section_id, 'reality') == '1' ? 'Reality' : 'TLS';
		};

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
		o.textvalue = function(section_id) {
			return E('span', { 'id': 'ev-state-' + section_id }, stateText(section_id));
		};

		o = s.taboption('basic', form.DummyValue, '_test', _('Test'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			return E('span', { 'id': 'ev-test-' + section_id }, ev.testText(ev.testResults[section_id]));
		};

		o = s.taboption('basic', form.DummyValue, '_ut', _('URL Test'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			return E('span', { 'id': 'ev-ut-' + section_id }, urltestText(section_id));
		};

		/* ===== URL Test groups ===== */
		s = m.section(form.GridSection, 'nodes', _('URL Test'),
			_('A URL Test group is a sing-box "urltest" outbound: sing-box probes its servers (default %s) and uses the fastest one. Use a group as main node, Default or rule target.').format(ev.URL_TEST_URL));
		s.addremove = true;
		s.anonymous = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add group');
		s.modaltitle = function(section_id) {
			return _('URL Test group') + ' » ' + (uci.get(CONFIG, section_id, 'remarks') || _('New group'));
		};
		s.filter = function(section_id) {
			return ev.isGroup(section_id);
		};
		s.handleAdd = function(ev_, name) {
			const section_id = this.map.data.add(CONFIG, this.sectiontype, ev.newName('g'));
			this.map.data.set(CONFIG, section_id, 'protocol', '_urltest');
			this.map.data.set(CONFIG, section_id, 'type', 'sing-box');
			this.map.data.set(CONFIG, section_id, 'urltest_url', ev.URL_TEST_URL);
			this.map.addedSection = section_id;
			return this.renderMoreOptionsModal(section_id);
		};
		s.handleRemove = function(section_id, ev_) {
			const refs = ev.references(section_id);
			if (refs.length) {
				ev.showResult(_('Delete group'), 'bad', _('This group is still used and was not deleted.'), _('Used by:') + '\n' + refs.join('\n'));
				return Promise.resolve();
			}
			return form.GridSection.prototype.handleRemove.apply(this, [ section_id, ev_ ]);
		};
		s.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, [ section_id ]);
			td.lastElementChild.insertBefore(E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(view_, 'handleUse', section_id)
			}, _('Use')), td.lastElementChild.firstChild);
			return td;
		};

		o = s.option(form.Value, 'remarks', _('Name'));
		o.rmempty = false;

		o = s.option(form.MultiValue, 'urltest_node', _('Servers'));
		o.rmempty = false;
		ev.servers().forEach(function(srv) {
			o.value(srv['.name'], srv.remarks || srv['.name']);
		});
		o.textvalue = function(section_id) {
			return _('%d server(s)').format(L.toArray(this.cfgvalue(section_id)).length);
		};
		o.validate = function(section_id, value) {
			if (!value || !value.length)
				return _('Select at least one server');
			return true;
		};

		o = s.option(form.Value, 'urltest_url', _('Test URL'),
			_('Use an https:// URL: for manual tests ("Test all servers now") sing-box ignores http:// URLs.'));
		o.placeholder = ev.URL_TEST_URL;
		o.default = ev.URL_TEST_URL;
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (!/^https?:\/\/\S+$/.test(value || ''))
				return _('Expecting an http:// or https:// URL');
			return true;
		};

		o = s.option(form.Value, 'urltest_interval', _('Interval'), _('How often sing-box re-tests the servers, e.g. 3m or 180.'));
		o.placeholder = '3m';
		o.modalonly = true;

		o = s.option(form.Value, 'urltest_tolerance', _('Tolerance (ms)'), _('Switch only if another server is faster by more than this.'));
		o.datatype = 'uinteger';
		o.placeholder = '50';
		o.modalonly = true;

		o = s.option(form.DummyValue, '_state', _('Status'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			if (ev.activeTarget() == section_id)
				return ev.badge(_('Active'), 'ok');
			return ev.references(section_id).length ? _('in use') : '-';
		};

		/* ===== Subscriptions ===== */
		s = m.section(form.GridSection, 'subscribe_list', _('Subscriptions'),
			_('Subscription URLs are parsed by the existing subscribe.lua; only VLESS nodes are imported, other node types are skipped and logged. Save first, then Update.'));
		s.addremove = true;
		s.anonymous = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add subscription');
		s.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, [ section_id ]);
			const box = td.lastElementChild;
			box.insertBefore(E('button', {
				'class': 'btn cbi-button cbi-button-remove',
				'title': _('Delete the nodes of this subscription'),
				'click': ui.createHandlerFn(view_, 'handleTruncate', section_id)
			}, _('Delete nodes')), box.firstChild);
			box.insertBefore(E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(view_, 'handleSubscribe', section_id)
			}, _('Update')), box.firstChild);
			return td;
		};

		o = s.option(form.Value, 'remark', _('Name'));
		o.rmempty = false;

		o = s.option(form.Value, 'url', _('Subscription URL'));
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return /^https?:\/\/\S+$/.test(value || '') ? true : _('Expecting an http:// or https:// URL');
		};
		o.textvalue = function(section_id) {
			const v = this.cfgvalue(section_id) || '';
			return v.length > 48 ? v.substr(0, 45) + '…' : v;
		};

		o = s.option(form.DummyValue, '_count', _('Nodes'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const remark = (uci.get(CONFIG, section_id, 'remark') || '').toLowerCase();
			return String(uci.sections(CONFIG, 'nodes').filter(function(n) { return n.add_mode == '2' && (n.group || '').toLowerCase() == remark; }).length);
		};

		o = s.option(form.ListValue, 'access_mode', _('Access method'));
		o.modalonly = true;
		o.value('', _('Auto'));
		o.value('direct', _('Direct'));
		o.value('proxy', _('Proxy'));

		o = s.option(form.Value, 'user_agent', _('User-Agent'));
		o.modalonly = true;
		o.placeholder = 'curl';

		o = s.option(form.Flag, 'allowInsecure', _('allowInsecure'),
			_('Keep the allowInsecure flag of imported nodes (certificate validation skipped). Off by default.'));
		o.modalonly = true;
		o.default = '0';
		o.rmempty = false;

		return m.render().then(L.bind(function(mapEl) {
			poll.add(L.bind(ev.refreshStatus, ev), 5);
			poll.add(L.bind(this.refreshLive, this), 10);
			return E('div', {}, [
				E('h2', {}, _('Node List')),
				ev.renderHeader(m, status, [
					' ',
					E('button', { 'class': 'btn cbi-button cbi-button-add', 'click': ui.createHandlerFn(this, 'handleImport') }, _('Import VLESS URL')),
					' ',
					E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleTestAll') }, _('Test all servers')),
					' ',
					E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleSubscribe', 'all') }, _('Update all subscriptions'))
				], true),
				this.placeLive(mapEl)
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
