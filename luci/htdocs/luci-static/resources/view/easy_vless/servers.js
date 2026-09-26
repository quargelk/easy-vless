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

/* Status = real usage (not "configured"): Active = the service is running
 * and this server is the main node / Default target; Selected = same, but the
 * service is stopped; In active group / Used by = referenced elsewhere;
 * Inactive = not used. Below: last Server Test and URL Test results. */
function stateText(sid) {
	const running = !!(ev.lastStatus && ev.lastStatus.running);
	const target = ev.activeTarget();
	const refs = ev.references(sid);
	let usage;
	if (uci.get(CONFIG, 'global', 'node') == sid || target == sid)
		usage = running ? ev.badge(_('Active'), 'ok') : ev.badge(_('Selected (stopped)'), 'idle');
	else if (ev.targetUses(target, sid))
		usage = running ? ev.badge(_('Active (group)'), 'ok') : ev.badge(_('In group (stopped)'), 'idle');
	else if (refs.length)
		usage = E('span', { 'title': _('Used by: %s').format(refs.join(', ')) }, _('Used by %d').format(refs.length));
	else
		usage = E('span', { 'style': 'opacity:.7' }, _('Inactive'));

	const lines = [ usage ];
	const t = ev.testResults[sid];
	if (t)
		lines.push(E('div', { 'style': 'font-size:90%' }, [ _('Test') + ': ', testShort(t) ]));
	const u = ev.urlTestResults[sid];
	const g = urltestLive(sid);
	if (u || g != null)
		lines.push(E('div', { 'style': 'font-size:90%' }, [ _('URL Test') + ': ', u ? testShort(u) : (g > 0 ? _('%d ms').format(g) : E('span', { 'style': 'color:#c62828' }, _('failed'))) ]));
	return E('div', {}, lines);
}

function testShort(r) {
	if (r.pending)
		return E('em', {}, _('testing…'));
	if (r.ok)
		return E('span', { 'title': '%s → HTTP %s'.format(r.url || '', r.http_code || '') }, [ ev.badge(_('PASS'), 'ok'), ' ', _('%d ms').format(r.delay) ]);
	return E('span', { 'title': r.error || '' }, [ ev.badge(_('FAIL'), 'bad'), ' ', E('small', {}, (r.error || '').length > 50 ? r.error.substr(0, 47) + '…' : (r.error || '')) ]);
}

/* Last delay sing-box measured for this server in a running URL Test group
 * (https://x.com by default); 0 = failed, null = no data. */
function urltestLive(sid) {
	if (!liveGroups)
		return null;
	let best = null;
	liveGroups.forEach(function(g) {
		(g.members || []).forEach(function(m) {
			if (m.id == sid && m.delay != null && (best == null || (m.delay > 0 && (best == 0 || m.delay < best))))
				best = m.delay;
		});
	});
	return best;
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
			const el = document.getElementById('ev-state-' + sid);
			if (el) dom.content(el, stateText(sid));
		});
		const box = document.getElementById('ev-urltest-results');
		if (box)
			dom.content(box, this.renderGroupResults());
	},

	/* Client-side filter of the Servers table (name / address / status text);
	 * display only, no UCI or backend involvement. */
	applyFilter: function() {
		const q = (this.filterText || '').trim().toLowerCase();
		document.querySelectorAll('#cbi-' + CONFIG + '-nodes tr.cbi-section-table-row').forEach(function(tr) {
			tr.style.display = (!q || tr.textContent.toLowerCase().indexOf(q) >= 0) ? '' : 'none';
		});
	},

	refreshLive: function() {
		ev.refreshStatus();
		this.applyFilter();
		return ev.callGroups().then(L.bind(function(res) {
			this.setGroups(res);
			this.refreshRows();
		}, this));
	},

	/* ---------- server actions ---------- */

	handleUse: function(sid) {
		return ev.exclusive(_('Use'), L.bind(function() {
			ev.setActiveTarget(sid);
			return ev.applyIfRunning(this.map).then(L.bind(this.refreshRows, this));
		}, this));
	},

	handleTest: function(sid) {
		return ev.exclusive(_('Server Test'), L.bind(function() {
			ev.testResults[sid] = { pending: true };
			this.refreshRows();
			return ev.serverTest(sid).then(L.bind(this.refreshRows, this));
		}, this));
	},

	handleUrlTest: function(sid) {
		return ev.exclusive(_('URL Test'), L.bind(function() {
			ev.urlTestResults[sid] = { pending: true };
			this.refreshRows();
			return ev.nodeUrlTest(sid).then(L.bind(this.refreshRows, this));
		}, this));
	},

	handleTestAll: function() {
		return ev.exclusive(_('Test all servers'), L.bind(function() {
			const ids = ev.servers().map(function(s) { return s['.name']; });
			ids.forEach(function(sid) { ev.testResults[sid] = { pending: true }; });
			this.refreshRows();
			return ids.reduce(L.bind(function(p, sid) {
				return p.then(L.bind(function() { return ev.serverTest(sid).then(L.bind(this.refreshRows, this)); }, this));
			}, this), Promise.resolve());
		}, this));
	},

	handleMove: function(sid, up) {
		return ev.exclusive(_('Move'), L.bind(function() {
			if (!ev.moveSection(sid, up, function(s) { return s.protocol == 'vless'; }))
				return;
			return ev.saveAndCommit(this.map);
		}, this));
	},

	handleImport: function() {
		const textarea = E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width:100%',
			'rows': 8,
			'placeholder': 'vless://uuid@host:443?security=reality&...#Name'
		});

		ui.showModal(_('Import VLESS URL'), [
			E('p', {}, _('One vless:// link per line (bulk import supported). Imported servers are saved and added to the list; existing servers are kept.')),
			textarea,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': ui.createHandlerFn(this, function() {
						const links = textarea.value.trim();
						if (!links) {
							ev.notify(_('Paste at least one vless:// link.'), 'warning');
							return;
						}
						return ev.exclusive(_('Import VLESS URL'), function() {
						ev.showBusy(_('Import VLESS URL'), _('Parsing links…'));
						return ev.callImport(links).then(function(res) {
							if (res.rpc_error)
								return ev.showResult(_('Import VLESS URL'), 'bad', _('Import request failed'), res.error);
							const summary = _('Links found: %d · imported: %d · skipped: %d').format(res.found || 0, res.added || 0, res.skipped || 0);
							const details = [ res.output, res.log ].filter(function(x) { return x; }).join('\n');
							if (res.added > 0) {
								const td = function(t) { return E('td', { 'class': 'td' }, t || '-'); };
								const table = E('table', { 'class': 'table' }, [
									E('tr', { 'class': 'tr table-titles' }, [ _('Name'), _('Address'), _('Port'), _('Transport'), _('Security'), 'Flow', 'SNI' ].map(function(t) { return E('th', { 'class': 'th' }, t); }))
								].concat(L.toArray(res.nodes).map(function(n) {
									return E('tr', { 'class': 'tr' }, [ td(n.remarks), td(n.address), td(n.port), td(n.transport),
										td(n.tls != '1' ? _('none') : (n.reality == '1' ? 'Reality' : 'TLS')), td(n.flow), td(n.sni) ]);
								})));
								ev.showResult(_('Import VLESS URL'), res.skipped ? 'warn' : 'ok', summary, details, table);
								const btn = document.querySelector('.modal .btn');
								if (btn)
									btn.addEventListener('click', function() { window.location.reload(); });
							}
							else {
								ev.showResult(_('Import VLESS URL'), 'bad', summary, (details || '') + '\n' +
									_('No server was imported (unsupported or invalid link, or a transport sing-box does not support).'));
							}
						});
						});
					})
				}, _('Import'))
			])
		]);
	},

	/* ---------- subscriptions ---------- */

	handleSubscribe: function(id) {
		return ev.exclusive(_('Update subscription'), L.bind(this.doSubscribe, this, id));
	},

	doSubscribe: function(id) {
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
		const name = uci.get(CONFIG, id, 'remark') || id;
		return ev.confirm(_('Delete nodes'), _('Delete all nodes of subscription "%s"? Nodes of other subscriptions and manual servers are not touched.').format(name))
			.then(function(ok) { if (ok) return this.doTruncate(id); }.bind(this));
	},

	doTruncate: function(id) {
		return ev.exclusive(_('Delete nodes'), function() { return ev.callSubscribe('truncate', id).then(function(res) {
			if (res.code !== 0)
				return ev.showResult(_('Subscription'), 'bad', res.output || res.error || _('Failed'));
			ev.showResult(_('Subscription'), 'ok', _('%d subscribed nodes deleted.').format(res.removed || 0));
			const btn = document.querySelector('.modal .btn');
			if (btn)
				btn.addEventListener('click', function() { window.location.reload(); });
		}); });
	},

	/* ---------- URL Test groups ---------- */

	renderGroupResults: function() {
		const groups = ev.groups();
		if (!groups.length)
			return '';

		if (!liveGroups)
			return E('p', { 'class': 'cbi-value-description' },
				_('No live results (%s). They come from the running sing-box when a group is the main node, Default or a rule target.').format(liveError || _('not running')));

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
		return ev.exclusive(_('URL Test'), L.bind(function() { return ev.callGroupTest(id).then(L.bind(function(res) {
			if (!res.ok) {
				ev.showResult(_('URL Test'), 'bad', res.error || _('Failed'));
				return;
			}
			this.setGroups(res);
			lastGroupTest = {};
			L.toArray(res.tested).forEach(function(t) { lastGroupTest[t.tag] = t; });
			this.refreshRows();
		}, this)); }, this));
	},

	/* Live URL Test results right below the URL Test groups section. */
	placeLive: function(mapEl) {
		const live = E('div', { 'class': 'cbi-section', 'style': ev.groups().length ? '' : 'display:none' }, [
			E('h4', {}, _('URL Test live results')),
			E('div', { 'id': 'ev-urltest-results' }, this.renderGroupResults())
		]);
		const sections = mapEl.querySelectorAll('.cbi-section');
		let anchor = null;
		sections.forEach(function(sec) {
			const h = sec.querySelector('h3');
			if (h && h.textContent == _('URL Test Groups'))
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
		ev.lastStatus = status;
		let m, s, o;
		const view_ = this;

		m = this.map = new form.Map(CONFIG);

		/* ===== Servers (VLESS only) ===== */
		s = this.serversSection = m.section(form.GridSection, 'nodes', _('Servers'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = false;
		s.nodescriptions = true;
		s.addbtntitle = _('Add VLESS');
		ev.compactWhenEmpty(s, _('No servers yet: use Add VLESS or Import VLESS URL.'));
		ev.commitOnModalSave(s, _('VLESS server'));
		/* the add button lives in the page toolbar (Add VLESS) */
		s.renderSectionAdd = function() { return E([]); };
		s.modaltitle = function(section_id) {
			return 'VLESS » ' + (uci.get(CONFIG, section_id, 'remarks') || _('New server'));
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
			const name = uci.get(CONFIG, section_id, 'remarks') || section_id;
			return ev.confirm(_('Delete server'), _('Delete server "%s"? This cannot be undone.').format(name)).then(L.bind(function(ok) {
				if (!ok) return;
				return ev.exclusive(_('Delete'), L.bind(function() {
				this.map.data.remove(CONFIG, section_id);
				return ev.saveAndCommit(this.map).then(function() { ev.notify(_('Server deleted.')); });
				}, this));
			}, this));
		};
		s.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, [ section_id ]);
			const box = td.lastElementChild;
			const sb = function(label, title, cls, fn, args) {
				return ev.smallButton(label, title, cls, ui.createHandlerFn.apply(ui, [ view_, fn ].concat(args)));
			};
			[
				sb(_('Use'), _('Use this server (main node, or Default target while the Main Router is the main node)'), 'cbi-button-apply', 'handleUse', [ section_id ]),
				sb(_('Test'), _('Server Test: HTTPS request to %s through this server (temporary sing-box instance)').format(ev.SERVER_TEST_URL), '', 'handleTest', [ section_id ]),
				sb(_('URL Test'), _('URL Test of this server: request to %s through it (temporary sing-box instance)').format(ev.URL_TEST_URL), '', 'handleUrlTest', [ section_id ]),
				ev.smallButton(_('Copy'), _('Copy the VLESS URL of this server'), 'cbi-button-action', ui.createHandlerFn(ev, 'showVlessUrl', section_id)),
				sb('↑', _('Up'), '', 'handleMove', [ section_id, true ]),
				sb('↓', _('Down'), '', 'handleMove', [ section_id, false ])
			].reverse().forEach(function(b) { box.insertBefore(b, box.firstChild); });
			return td;
		};

		/* VLESS editor: one flat form, fields shown only when relevant. */
		o = s.option(form.Value, 'remarks', _('Name'));
		o.rmempty = false;

		o = s.option(form.Value, 'address', _('Address'));
		o.datatype = 'host';
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('Port'));
		o.datatype = 'port';
		o.default = '443';
		o.rmempty = false;

		o = s.option(form.Value, 'uuid', _('UUID'));
		o.modalonly = true;
		o.rmempty = false;
		o.password = true;
		o.validate = function(section_id, value) {
			if (!/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(value || ''))
				return _('Expecting a UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)');
			return true;
		};

		o = s.option(form.ListValue, 'transport', _('Transport'));
		o.value('tcp', 'TCP');
		o.value('ws', 'WebSocket');
		o.value('grpc', 'gRPC');
		o.value('httpupgrade', 'HTTPUpgrade');
		o.default = 'tcp';
		o.textvalue = function(section_id) {
			const v = this.cfgvalue(section_id) || 'tcp';
			return { raw: 'TCP', tcp: 'TCP', ws: 'WebSocket', grpc: 'gRPC', httpupgrade: 'HTTPUpgrade' }[v] || v;
		};

		o = s.option(form.Value, 'ws_host', _('WebSocket Host'));
		o.modalonly = true;
		o.depends('transport', 'ws');

		o = s.option(form.Value, 'ws_path', _('WebSocket path'));
		o.modalonly = true;
		o.placeholder = '/';
		o.depends('transport', 'ws');

		o = s.option(form.Value, 'grpc_serviceName', _('gRPC service name'));
		o.modalonly = true;
		o.depends('transport', 'grpc');

		o = s.option(form.Value, 'httpupgrade_host', _('HTTPUpgrade Host'));
		o.modalonly = true;
		o.depends('transport', 'httpupgrade');

		o = s.option(form.Value, 'httpupgrade_path', _('HTTPUpgrade path'));
		o.modalonly = true;
		o.placeholder = '/';
		o.depends('transport', 'httpupgrade');

		o = s.option(form.Flag, 'tls', _('TLS'));
		o.modalonly = true;
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'reality', _('Reality'));
		o.modalonly = true;
		o.depends('tls', '1');

		o = s.option(form.DummyValue, '_security', _('Security'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			if (uci.get(CONFIG, section_id, 'tls') != '1')
				return _('none');
			return uci.get(CONFIG, section_id, 'reality') == '1' ? 'Reality' : 'TLS';
		};

		o = s.option(form.Value, 'tls_serverName', _('SNI'), _('Server name for TLS / Reality.'));
		o.modalonly = true;
		o.datatype = 'hostname';
		o.depends('tls', '1');

		o = s.option(form.Flag, 'utls', _('uTLS'), _('Use a browser TLS fingerprint (always on with Reality).'));
		o.modalonly = true;
		o.depends({ tls: '1', reality: '0' });

		o = s.option(form.ListValue, 'fingerprint', _('Fingerprint'));
		o.modalonly = true;
		[ 'chrome', 'firefox', 'safari', 'edge', 'ios', 'android', 'random', 'randomized' ].forEach(function(fp) {
			o.value(fp);
		});
		o.default = 'chrome';
		o.depends('reality', '1');
		o.depends('utls', '1');

		o = s.option(form.Value, 'reality_publicKey', _('Public Key'));
		o.modalonly = true;
		o.depends('reality', '1');
		o.validate = function(section_id, value) {
			if (!/^[A-Za-z0-9_-]{43}$/.test(value || ''))
				return _('Expecting a 43-character base64url X25519 public key');
			return true;
		};

		o = s.option(form.Value, 'reality_shortId', _('Short ID'));
		o.modalonly = true;
		o.depends('reality', '1');
		o.validate = function(section_id, value) {
			if (value && !/^([0-9a-fA-F]{2}){1,8}$/.test(value))
				return _('Expecting an even number of hexadecimal characters (at most 16)');
			return true;
		};

		o = s.option(form.ListValue, 'flow', _('Flow'), _('xtls-rprx-vision needs TCP with TLS or Reality.'));
		o.modalonly = true;
		o.value('', _('none'));
		o.value('xtls-rprx-vision', 'xtls-rprx-vision');
		o.depends({ transport: 'tcp', tls: '1' });

		o = s.option(form.Flag, 'tls_allowInsecure', _('Allow insecure'),
			_('Do not verify the server certificate. Not recommended.'));
		o.modalonly = true;
		o.depends({ tls: '1', reality: '0' });

		o = s.option(form.DummyValue, '_state', _('Status'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			return E('span', { 'id': 'ev-state-' + section_id }, stateText(section_id));
		};

		/* ===== URL Subscriptions ===== */
		s = m.section(form.GridSection, 'subscribe_list', _('URL Subscriptions'),
			_('Only VLESS nodes are imported; other types are skipped and counted in the log.'));
		s.addremove = true;
		s.anonymous = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add subscription');
		ev.compactWhenEmpty(s, _('No subscriptions.'));
		ev.commitOnModalSave(s, _('Subscription'));
		s.modaltitle = function(section_id) {
			return _('URL Subscription') + ' » ' + (uci.get(CONFIG, section_id, 'remark') || _('New subscription'));
		};
		s.handleRemove = function(section_id, ev_) {
			const name = uci.get(CONFIG, section_id, 'remark') || section_id;
			return ev.confirm(_('Delete subscription'), _('Delete subscription "%s"? Its nodes are kept.').format(name)).then(L.bind(function(ok) {
				if (!ok) return;
				return ev.exclusive(_('Delete'), L.bind(function() {
				this.map.data.remove(CONFIG, section_id);
				return ev.saveAndCommit(this.map).then(function() { ev.notify(_('Subscription deleted (its nodes are kept; use Delete nodes to remove them).')); });
				}, this));
			}, this));
		};
		s.renderSectionAdd = function(extra_class) {
			const el = form.GridSection.prototype.renderSectionAdd.apply(this, [ extra_class ]);
			if (uci.sections(CONFIG, 'subscribe_list').length)
				el.appendChild(E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'style': 'margin-left:.5em',
					'click': ui.createHandlerFn(view_, 'handleSubscribe', 'all')
				}, _('Update all subscriptions')));
			return el;
		};
		s.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, [ section_id ]);
			const box = td.lastElementChild;
			box.insertBefore(ev.smallButton(_('Delete nodes'), _('Delete the nodes of this subscription'), 'cbi-button-remove',
				ui.createHandlerFn(view_, 'handleTruncate', section_id)), box.firstChild);
			box.insertBefore(ev.smallButton(_('Update'), _('Download and import this subscription now'), 'cbi-button-action',
				ui.createHandlerFn(view_, 'handleSubscribe', section_id)), box.firstChild);
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
			return E('span', { 'title': v }, v.length > 40 ? v.substr(0, 37) + '…' : v);
		};

		o = s.option(form.DummyValue, '_count', _('Nodes'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const remark = (uci.get(CONFIG, section_id, 'remark') || '').toLowerCase();
			return String(uci.sections(CONFIG, 'nodes').filter(function(n) { return n.add_mode == '2' && (n.group || '').toLowerCase() == remark; }).length);
		};

		/* Status: subscribe.lua stores the md5 of the last downloaded content
		 * (option md5) after a successful update; nothing else is recorded. */
		o = s.option(form.DummyValue, '_status', _('Status'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			return uci.get(CONFIG, section_id, 'md5')
				? ev.badge(_('Updated'), 'ok')
				: ev.badge(_('Not updated yet'), 'idle');
		};

		/* User-Agent: subscribe.lua sends option user_agent as the HTTP
		 * User-Agent header (unset/"curl" = curl's default, as before). */
		o = s.option(form.ListValue, '_ua_mode', _('User-Agent'),
			_('HAPP sends "User-Agent: HAPP" (for providers that serve the node list only to the HAPP app).'));
		o.modalonly = true;
		o.value('', _('Default (curl)'));
		o.value('HAPP', 'HAPP');
		o.value('custom', _('Custom'));
		o.cfgvalue = function(section_id) {
			const ua = uci.get(CONFIG, section_id, 'user_agent');
			if (!ua || ua == 'curl') return '';
			return ua == 'HAPP' ? 'HAPP' : 'custom';
		};
		o.write = function(section_id, value) {
			if (value == 'HAPP')
				uci.set(CONFIG, section_id, 'user_agent', 'HAPP');
		};
		o.remove = function(section_id) {
			if (this.isActive(section_id))
				uci.unset(CONFIG, section_id, 'user_agent');
		};

		o = s.option(form.Value, 'user_agent', _('Custom User-Agent'));
		o.modalonly = true;
		o.depends('_ua_mode', 'custom');
		o.rmempty = false;
		o.retain = true;   /* hidden (Default/HAPP): leave the value to _ua_mode */
		o.validate = function(section_id, value) {
			return /^[A-Za-z0-9 ._\/()+;:,=-]+$/.test(value || '') ? true : _('Letters, digits, spaces and . _ / ( ) + ; : , = - only');
		};

		o = s.option(form.ListValue, 'access_mode', _('Access method'),
			_('How the subscription is downloaded: directly, through the running proxy, or automatically.'));
		o.modalonly = true;
		o.value('', _('Auto'));
		o.value('direct', _('Direct'));
		o.value('proxy', _('Proxy'));

		o = s.option(form.Flag, 'allowInsecure', _('allowInsecure'),
			_('Keep the allowInsecure flag of imported nodes (certificate validation skipped). Off by default.'));
		o.modalonly = true;
		o.default = '0';
		o.rmempty = false;

		/* ===== URL Test Groups ===== */
		s = m.section(form.GridSection, 'nodes', _('URL Test Groups'),
			_('sing-box tests the servers of a group (default %s) and uses the fastest one. Use a group as main node, Default or rule target.').format(ev.URL_TEST_URL));
		s.addremove = true;
		s.anonymous = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add group');
		ev.compactWhenEmpty(s, _('No URL Test groups.'));
		ev.commitOnModalSave(s, _('URL Test group'));
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
			const name = uci.get(CONFIG, section_id, 'remarks') || section_id;
			return ev.confirm(_('Delete group'), _('Delete URL Test group "%s"? This cannot be undone.').format(name)).then(L.bind(function(ok) {
				if (!ok) return;
				return ev.exclusive(_('Delete'), L.bind(function() {
				this.map.data.remove(CONFIG, section_id);
				return ev.saveAndCommit(this.map).then(function() { ev.notify(_('URL Test group deleted.')); });
				}, this));
			}, this));
		};
		s.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, [ section_id ]);
			td.lastElementChild.insertBefore(ev.smallButton(_('Use'), _('Use this group'), 'cbi-button-apply',
				ui.createHandlerFn(view_, 'handleUse', section_id)), td.lastElementChild.firstChild);
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
			const running = !!(ev.lastStatus && ev.lastStatus.running);
			if (ev.activeTarget() == section_id)
				return running ? ev.badge(_('Active'), 'ok') : ev.badge(_('Selected (stopped)'), 'idle');
			const refs = ev.references(section_id);
			return refs.length ? E('span', { 'title': refs.join(', ') }, _('Used by %d').format(refs.length)) : E('span', { 'style': 'opacity:.7' }, _('Inactive'));
		};

		return m.render().then(L.bind(function(mapEl) {
			poll.add(L.bind(ev.refreshStatus, ev), 5);
			poll.add(L.bind(this.refreshLive, this), 10);
			/* every save re-renders the map contents: keep the live URL Test
			 * panel and the active filter after such a re-render */
			const view_ = this, renderContents = m.renderContents;
			m.renderContents = function() {
				return renderContents.apply(this, arguments).then(function(el) {
					view_.placeLive(el);
					view_.applyFilter();
					return el;
				});
			};
			return E('div', { 'id': 'ev-nodelist', 'class': 'ev-page' }, [
				ev.pageStyle(),
				E('h2', {}, _('Node List')),
				ev.renderHeader(m, status, null, true, false),
				E('div', { 'style': 'margin:.6em 0' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-add', 'click': ui.createHandlerFn(this, 'handleImport') }, _('Import VLESS URL')),
					' ',
					E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleTestAll') }, _('Test all servers')),
					' ',
					E('button', { 'class': 'btn cbi-button cbi-button-add', 'click': ui.createHandlerFn(this, function(ev_) {
						return this.serversSection.handleAdd(ev_);
					}) }, _('Add VLESS')),
					' ',
					E('input', { 'type': 'search', 'class': 'cbi-input-text', 'style': 'width:14em;vertical-align:middle',
						'placeholder': _('Filter servers…'), 'title': _('Filter by name, address or status'),
						'input': L.bind(function(e) { this.filterText = e.target.value; this.applyFilter(); }, this) })
				]),
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
