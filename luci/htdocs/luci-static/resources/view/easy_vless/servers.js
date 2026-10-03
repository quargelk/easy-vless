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
 * service is stopped (ev.selectedNode); In active group / Used by = referenced elsewhere;
 * Inactive = not used. Below: the URL Test result and the source (manual or
 * the subscription the server came from). The Server Test result has its own
 * column (Latency). */
function stateText(sid) {
	const running = !!(ev.lastStatus && ev.lastStatus.running);
	const target = ev.selectedNode();
	const refs = ev.references(sid);
	let usage;
	if (target == sid)
		usage = running ? ev.badge(_('Active'), 'ok') : ev.badge(_('Selected (stopped)'), 'idle');
	else if (ev.targetUses(target, sid))
		usage = running ? ev.badge(_('Active (group)'), 'ok') : ev.badge(_('In group (stopped)'), 'idle');
	else if (refs.length)
		usage = E('span', { 'title': _('Used by: %s').format(refs.join(', ')) }, _('Used by %d').format(refs.length));
	else
		usage = E('span', { 'style': 'opacity:.7' }, _('Inactive'));

	const lines = [ usage ];
	const u = ev.testInfo(sid, 'url');
	const g = urltestLive(sid);
	if (u.state != 'none')
		lines.push(E('div', { 'style': 'font-size:90%' }, [ _('URL Test') + ': ', ev.testCell(sid, 'url') ]));
	else if (g != null)
		lines.push(E('div', { 'style': 'font-size:90%' }, [ _('URL Test') + ': ', g > 0 ? _('%d ms').format(g) : E('span', { 'style': 'color:#c62828' }, _('failed')) ]));
	lines.push(E('div', { 'style': 'font-size:85%;opacity:.7' }, sourceText(sid)));
	return E('div', {}, lines);
}

/* Where a server came from: its subscription, or added by hand. */
function sourceText(sid) {
	const group = uci.get(CONFIG, sid, 'group');
	return (uci.get(CONFIG, sid, 'add_mode') == '2' && group) ? _('Subscription: %s').format(group) : _('Added manually');
}

/* The subscription (subscribe_list section) a server was imported from. */
function sourceSubscription(sid) {
	const group = (uci.get(CONFIG, sid, 'group') || '').toLowerCase();
	if (uci.get(CONFIG, sid, 'add_mode') != '2' || !group)
		return null;
	return uci.sections(CONFIG, 'subscribe_list').filter(function(s) { return (s.remark || '').toLowerCase() == group; })[0] || null;
}

/* Nodes of a subscription the user deleted: [{ key, name }] (UCI list
 * excluded_node, entries "<key> <name>", written by nodes.lua). */
function excludedNodes(subId) {
	return L.toArray(uci.get(CONFIG, subId, 'excluded_node')).map(function(v) {
		const m = String(v).match(/^([0-9a-f]{16})\s*(.*)$/);
		return m ? { key: m[1], name: m[2] || m[1] } : null;
	}).filter(function(x) { return x; });
}

function sourceKey(sid) {
	const group = uci.get(CONFIG, sid, 'group');
	return (uci.get(CONFIG, sid, 'add_mode') == '2' && group) ? 'sub:' + group.toLowerCase() : 'manual';
}

/* Node List view settings (sort, filters) of this browser. */
const VIEW_STORE = 'easy_vless.nodelist';

function readView() {
	try {
		const v = JSON.parse(window.localStorage.getItem(VIEW_STORE) || 'null');
		return (v && typeof(v) == 'object') ? v : {};
	}
	catch (e) {
		return {};
	}
}

function writeView(v) {
	try { window.localStorage.setItem(VIEW_STORE, JSON.stringify(v)); } catch (e) {}
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
			ev.callGroups(),
			ev.refreshTests(),
			ev.callSubscribe('state')
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
			el = document.getElementById('ev-lat-' + sid);
			if (el) dom.content(el, ev.testCell(sid, 'server', true));
			[ [ 'server', 'ev-btn-test-' ], [ 'url', 'ev-btn-urltest-' ] ].forEach(function(k) {
				const b = document.getElementById(k[1] + sid);
				if (!b)
					return;
				const busy = ev.testBusy(sid, k[0]);
				b.disabled = busy;
				b.classList.toggle('ev-busy', busy);
			});
		});
		const box = document.getElementById('ev-urltest-results');
		if (box)
			dom.content(box, this.renderGroupResults());
		this.renderTestProgress();
		this.applyView();
	},

	/* Test All button: progress of the running tests, Cancel. */
	renderTestProgress: function() {
		const box = document.getElementById('ev-testall');
		if (!box)
			return;
		const st = ev.testState;
		const pending = st.queue.length + (st.current ? 1 : 0);
		if (st.running && pending) {
			const total = Math.max(st.total, st.done + pending);
			dom.content(box, [
				E('button', { 'class': 'btn cbi-button', 'disabled': '', 'id': 'ev-testall-btn' }, [
					E('span', { 'class': 'spinning', 'style': 'display:inline-block;width:1em' }, ' '), ' ',
					_('Testing… %d of %d').format(Math.min(st.done + 1, total), total) ]),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-reset', 'id': 'ev-testall-cancel', 'title': _('Drop the queued tests; the running test finishes'),
					'click': ui.createHandlerFn(this, 'handleCancelTests') }, _('Cancel'))
			]);
		}
		else {
			dom.content(box, E('button', { 'class': 'btn cbi-button cbi-button-action', 'id': 'ev-testall-btn',
				'title': _('Server Test of every server, one after another'),
				'click': ui.createHandlerFn(this, 'handleTestAll') }, _('Test All')));
		}
	},

	/* Rows of the Servers table (not the URL Test groups, same section type). */
	serverRows: function() {
		return Array.prototype.filter.call(document.querySelectorAll('tr.cbi-section-table-row[data-sid]'), function(tr) {
			return ev.isServer(tr.getAttribute('data-sid'));
		});
	},

	/* Sort and filter the Servers table (display only: no UCI change; the
	 * saved order stays the one of the Up / Down buttons). */
	applyView: function() {
		const v = this.viewState || {};
		const q = (v.text || '').trim().toLowerCase();
		const rows = this.serverRows();
		if (!rows.length)
			return;
		const recs = rows.map(function(tr, i) {
			const sid = tr.getAttribute('data-sid');
			const r = ev.sortRecord(sid, ev.servers().findIndex(function(s) { return s['.name'] == sid; }));
			r.tr = tr;
			return r;
		});
		let shown = 0;
		recs.forEach(function(r) {
			const info = ev.testInfo(r.id, 'server');
			let ok = !q || r.tr.textContent.toLowerCase().indexOf(q) >= 0;
			if (ok && v.status && v.status != 'all')
				ok = (v.status == 'testing') ? (info.state == 'testing' || info.state == 'queued') : (r.state == v.status);
			if (ok && v.source && v.source != 'all')
				ok = sourceKey(r.id) == v.source;
			r.tr.style.display = ok ? '' : 'none';
			if (ok) shown++;
		});
		const mode = v.sort || 'default';
		const parent = rows[0].parentNode;
		ev.sortRecords(recs, mode).forEach(function(r) { parent.appendChild(r.tr); });
		parent.classList.toggle('ev-sorted', mode != 'default');
		const cnt = document.getElementById('ev-shown');
		if (cnt)
			cnt.textContent = (shown < rows.length) ? _('%d of %d servers shown').format(shown, rows.length) : _('%d servers').format(rows.length);
	},

	setView: function(key, value) {
		this.viewState[key] = value;
		writeView({ sort: this.viewState.sort, status: this.viewState.status, source: this.viewState.source });
		this.applyView();
	},

	refreshLive: function() {
		ev.refreshStatus();
		ev.refreshTests();
		return ev.callGroups().then(L.bind(function(res) {
			this.setGroups(res);
			this.refreshRows();
		}, this));
	},

	/* ---------- server actions ---------- */

	handleUse: function(sid) {
		return ev.exclusive(_('Use'), L.bind(function() {
			const changed = ev.setActiveTarget(sid);
			if (!changed.length) {
				ev.notify(_('%s is already the selected node; nothing was changed.').format(ev.label(sid)));
				return;
			}
			/* names read before the commit re-renders the form */
			const names = ev.changedEntries(changed).join(', ');
			return ev.applyIfRunning(this.map).then(L.bind(function() {
				ev.notify(_('%s is now the target of: %s').format(ev.label(sid), names));
				this.refreshRows();
			}, this));
		}, this));
	},

	/* Tests are queued on the router (ev.queueTests): a click on a server
	 * that is already queued or being tested changes nothing, the button
	 * shows "Testing…" until the result is there. */
	handleTest: function(sid) {
		if (ev.testBusy(sid, 'server'))
			return Promise.resolve();
		return ev.queueTests('server', [ sid ]);
	},

	handleUrlTest: function(sid) {
		if (ev.testBusy(sid, 'url'))
			return Promise.resolve();
		return ev.queueTests('url', [ sid ]);
	},

	/* Test All: Server Test of every server, one after another (the router
	 * never runs more than one temporary sing-box instance for tests). */
	handleTestAll: function() {
		const ids = ev.servers().map(function(s) { return s['.name']; });
		if (!ids.length)
			return Promise.resolve();
		return ev.queueTests('server', ids);
	},

	handleCancelTests: function() {
		return ev.cancelTests();
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

	/* Update: runs on the router (subscribe.lua, detached); the row shows
	 * "Updating…" and then the result (nodes received, before/now, or the
	 * reason of a failure - existing nodes are kept then). A second click
	 * while an update runs changes nothing. */
	handleSubscribe: function(id) {
		if (ev.subBusy(id) || ev.subBusy('all'))
			return Promise.resolve();
		const names = (id && id != 'all') ? [ uci.get(CONFIG, id, 'remark') || id ] : uci.sections(CONFIG, 'subscribe_list').map(function(s) { return s.remark || s['.name']; });
		return ev.updateSubscription(id || 'all', L.bind(this.renderSubscriptionState, this)).then(L.bind(function(r) {
			if (!r.ok && !r.results)
				ev.notify(_('Subscription update failed: %s').format(r.error), 'error');
			else if (r.timeout)
				ev.notify(r.error, 'warning');
			else {
				const ids = Object.keys(r.results);
				const bad = ids.filter(function(k) { return [ 'ok', 'unchanged' ].indexOf(r.results[k].status) < 0; });
				const got = ids.reduce(function(n, k) { return n + (r.results[k].status == 'ok' ? (r.results[k].found || 0) : 0); }, 0);
				if (!ids.length)
					ev.notify(_('Subscription update finished without a result; check the log on Main.'), 'warning');
				else if (bad.length)
					ev.notify(_('Subscription update: %s - %s. Existing nodes were kept.').format(
						bad.map(function(k) { return r.results[k].remark || k; }).join(', '), ev.subResultText(bad[0]).text), 'warning');
				else
					ev.notify(_('Subscription updated (%s): %d nodes received.').format(names.join(', '), got));
			}
			return this.reloadNodes();
		}, this));
	},

	/* The node list changed on the router: reload UCI and re-render. */
	reloadNodes: function() {
		uci.unload(CONFIG);
		return this.map.load().then(L.bind(function() {
			return this.map.renderContents();
		}, this)).then(L.bind(function() {
			const bar = document.getElementById('ev-viewbar');
			if (bar)
				bar.parentNode.replaceChild(this.renderViewBar(), bar);
			return ev.refreshTests();
		}, this)).then(L.bind(this.refreshRows, this));
	},

	refreshSubscriptions: function() {
		return ev.refreshSubscriptions().then(L.bind(this.renderSubscriptionState, this));
	},

	/* Status column and buttons of the subscriptions (Updating… / result). */
	renderSubscriptionState: function() {
		const anyBusy = ev.subBusy(null);
		uci.sections(CONFIG, 'subscribe_list').forEach(function(s) {
			const id = s['.name'];
			const el = document.getElementById('ev-sub-' + id);
			if (el)
				dom.content(el, ev.subResultCell(id));
			[ 'ev-sub-update-', 'ev-sub-truncate-' ].forEach(function(p) {
				const b = document.getElementById(p + id);
				if (b) b.disabled = anyBusy;
			});
		});
		const all = document.getElementById('ev-sub-update-all');
		if (all) {
			all.disabled = anyBusy;
			all.textContent = anyBusy ? _('Updating…') : _('Update all subscriptions');
		}
	},

	/* ---------- deleting servers (rpcd "nodes": subscribe.lua + nodes.lua) ---------- */

	/* One server. A subscription node is remembered by its subscription
	 * (excluded_node), so an update does not import it again. */
	doDeleteServer: function(sid) {
		return ev.exclusive(_('Delete'), L.bind(function() {
			return ev.callNodes('delete', sid).then(L.bind(function(res) {
				if (!res.ok)
					return ev.showResult(_('Delete server'), 'bad', _('The server was not deleted.'), ev.nodesError(res));
				ev.notify(res.excluded
					? _('Server deleted. Updates of its subscription will not import it again.')
					: _('Server deleted.'));
				return this.reloadNodes();
			}, this));
		}, this));
	},

	/* Delete all nodes: the router says first what it would do (servers,
	 * URL Test groups, targets, the main node); nothing happens before the
	 * user has confirmed exactly that. */
	handleDeleteAll: function() {
		if (ev.subBusy(null)) {
			ev.notify(_('A subscription update is running; try again when it has finished.'), 'warning');
			return Promise.resolve();
		}
		return ev.callNodes('delete_all_plan').then(L.bind(function(plan) {
			if (!plan.ok)
				return ev.showResult(_('Delete all nodes'), 'bad', _('Nothing was deleted.'), ev.nodesError(plan));
			const c = plan.counts || {};
			const total = (c.manual || 0) + (c.subscription || 0);
			if (!total) {
				ev.notify(_('There are no servers to delete.'));
				return;
			}
			const items = [];
			if (c.manual)
				items.push(_('%d server(s) added manually or by link: deleted for good.').format(c.manual));
			if (c.subscription)
				items.push(_('%d server(s) of subscriptions: deleted. The subscriptions themselves stay, and their next update imports the servers again.').format(c.subscription));
			ev.arr(plan.changes).forEach(function(ch) {
				if (ch.kind == 'group_removed')
					items.push(_('URL Test group "%s" has no server left and is deleted too.').format(ch.name));
				else if (ch.kind == 'group_shrunk')
					items.push(_('URL Test group "%s" loses the deleted servers.').format(ch.name));
				else if (ch.kind == 'default')
					items.push(_('Main Router: Default becomes Direct.'));
				else if (ch.kind == 'rule')
					items.push(_('Main Router: the target of rule "%s" becomes "Default target".').format(ch.name));
				else if (ch.kind == 'main')
					items.push(_('The main node is one of these servers: it is cleared, the main switch is turned off and Easy VLESS is stopped.'));
			});
			const body = E('div', {}, [
				E('p', {}, E('strong', {}, _('This deletes every server of the Node List. It cannot be undone.'))),
				E('ul', {}, items.map(function(t) { return E('li', {}, t); })),
				E('p', {}, _('Rules, subscriptions, DNS and forwarding settings are kept.'))
			]);
			return ev.confirm(_('Delete all nodes'), body, _('Delete all nodes')).then(L.bind(function(ok) {
				if (ok)
					return this.doDeleteAll();
			}, this));
		}, this));
	},

	doDeleteAll: function() {
		return ev.exclusive(_('Delete all nodes'), L.bind(function() {
			ev.showBusy(_('Delete all nodes'), _('Deleting the servers…'));
			return ev.callNodes('delete_all').then(L.bind(function(res) {
				const n = ev.arr(res.removed).length;
				if (!res.ok && res.error != 'dangling') {
					ev.showResult(_('Delete all nodes'), 'bad', _('Nothing was deleted.'), ev.nodesError(res));
					return;
				}
				/* the service is stopped / restarted detached: wait for it */
				const wait = (res.service && res.service != 'none') ? ev.waitIdle(res.log_mark, 60000) : Promise.resolve();
				if (res.service == 'stop')
					ev.showBusy(_('Delete all nodes'), _('Stopping Easy VLESS (no main node is left)…'));
				else if (res.service == 'restart')
					ev.showBusy(_('Delete all nodes'), _('Restarting Easy VLESS with the changed targets…'));
				return wait.then(L.bind(function() {
					ui.hideModal();
					ev.refreshStatus();
					if (!res.ok)
						ev.showResult(_('Delete all nodes'), 'warn', _('%d node(s) deleted.').format(n), ev.nodesError(res));
					else
						ev.notify(res.service == 'stop'
							? _('%d node(s) deleted. Easy VLESS was stopped: no main node is left.').format(n)
							: _('%d node(s) deleted.').format(n));
					return this.reloadNodes();
				}, this));
			}, this));
		}, this));
	},

	/* Nodes of a subscription the user deleted: list, restore one or all. */
	handleExcluded: function(id) {
		const name = uci.get(CONFIG, id, 'remark') || id;
		const list = excludedNodes(id);
		const restore = L.bind(function(key) {
			ui.hideModal();
			return ev.exclusive(_('Restore'), L.bind(function() {
				return ev.callNodes('restore', id, key || '').then(L.bind(function(res) {
					if (!res.ok)
						return ev.showResult(_('Deleted nodes'), 'bad', _('Nothing was restored.'), ev.nodesError(res));
					ev.notify(_('%d node(s) of "%s" are no longer marked as deleted. Press Update to import them again.').format(res.restored || 0, name));
					return this.reloadNodes();
				}, this));
			}, this));
		}, this);
		ui.showModal(_('Deleted nodes'), [
			E('p', {}, _('Servers of the subscription "%s" that you deleted. Updates do not import them again until you restore them.').format(name)),
			E('table', { 'class': 'table' }, list.map(function(x) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, x.name),
					E('td', { 'class': 'td right' }, E('button', { 'class': 'btn cbi-button', 'click': function() { return restore(x.key); } }, _('Restore')))
				]);
			})),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close')),
				' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': function() { return restore(null); } }, _('Restore all'))
			])
		]);
	},

	handleTruncate: function(id) {
		const name = uci.get(CONFIG, id, 'remark') || id;
		if (ev.subBusy(null))
			return Promise.resolve();
		return ev.confirm(_('Delete nodes'), _('Delete all nodes of subscription "%s"? Nodes of other subscriptions and manual servers are not touched.').format(name))
			.then(function(ok) { if (ok) return this.doTruncate(id); }.bind(this));
	},

	doTruncate: function(id) {
		return ev.exclusive(_('Delete nodes'), L.bind(function() { return ev.callSubscribe('truncate', id).then(L.bind(function(res) {
			if (res.code !== 0)
				return ev.showResult(_('Subscription'), 'bad', res.output || res.error || _('Failed'));
			ev.notify(_('%d subscribed nodes deleted.').format(res.removed || 0));
			return this.reloadNodes();
		}, this)); }, this));
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
		ev.setSubState(data[4]);
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
		ev.compactWhenEmpty(s, _('No servers yet: paste a vless:// link with Import VLESS URL, or enter the settings by hand with Add VLESS.'));
		/* an edited server gets tested again: its old results are dropped */
		ev.commitOnModalSave(s, _('VLESS server'), function(sid) { return ev.clearTestResults([ sid ]); });
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
			const sub = sourceSubscription(section_id);
			return ev.confirm(_('Delete server'), sub
				? _('Delete server "%s"? It was imported from the subscription "%s": updates of that subscription will not import it again. "Deleted nodes" in the subscription row brings it back.').format(name, sub.remark)
				: _('Delete server "%s"? This cannot be undone.').format(name)).then(function(ok) {
				if (ok)
					return view_.doDeleteServer(section_id);
			});
		};
		s.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, [ section_id ]);
			const box = td.lastElementChild;
			const sb = function(label, title, cls, fn, args) {
				return ev.smallButton(label, title, cls, ui.createHandlerFn.apply(ui, [ view_, fn ].concat(args)));
			};
			const tb = function(label, title, fn, kind, id) {
				const b = sb(label, title, 'ev-test-btn', fn, [ section_id ]);
				b.id = id + section_id;
				b.disabled = ev.testBusy(section_id, kind);
				b.classList.toggle('ev-busy', b.disabled);
				return b;
			};
			[
				sb(_('Use'), _('Use this server: it becomes the main node, or - while the Main Router is the main node - replaces the selected server in Default and in every rule target that points to it'), 'cbi-button-apply', 'handleUse', [ section_id ]),
				tb(_('Test'), _('Server Test: HTTPS request to %s through this server (temporary sing-box instance)').format(ev.SERVER_TEST_URL), 'handleTest', 'server', 'ev-btn-test-'),
				tb(_('URL Test'), _('URL Test of this server: request to %s through it (temporary sing-box instance)').format(ev.URL_TEST_URL), 'handleUrlTest', 'url', 'ev-btn-urltest-'),
				ev.smallButton(_('Copy'), _('Copy the VLESS URL of this server'), 'cbi-button-action', ui.createHandlerFn(ev, 'showVlessUrl', section_id)),
				sb('↑', _('Up', 'move row'), 'ev-move', 'handleMove', [ section_id, true ]),
				sb('↓', _('Down', 'move row'), 'ev-move', 'handleMove', [ section_id, false ])
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

		/* Last Server Test: latency, Testing… / Queued, Failed, Not tested */
		o = s.option(form.DummyValue, '_latency', _('Latency'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			return E('span', { 'id': 'ev-lat-' + section_id }, ev.testCell(section_id, 'server', true));
		};

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
		ev.compactWhenEmpty(s, _('No subscriptions. If your provider gave you a subscription link (https://...), add it with Add subscription.'));
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
					'id': 'ev-sub-update-all',
					'click': ui.createHandlerFn(view_, 'handleSubscribe', 'all')
				}, _('Update all subscriptions')));
			return el;
		};
		s.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, [ section_id ]);
			const box = td.lastElementChild;
			const del = ev.smallButton(_('Delete nodes'), _('Delete the nodes of this subscription'), 'cbi-button-remove',
				ui.createHandlerFn(view_, 'handleTruncate', section_id));
			del.id = 'ev-sub-truncate-' + section_id;
			const upd = ev.smallButton(_('Update'), _('Download and import this subscription now'), 'cbi-button-action',
				ui.createHandlerFn(view_, 'handleSubscribe', section_id));
			upd.id = 'ev-sub-update-' + section_id;
			del.disabled = upd.disabled = ev.subBusy(null);
			box.insertBefore(del, box.firstChild);
			const gone = excludedNodes(section_id).length;
			if (gone)
				box.insertBefore(ev.smallButton(_('Deleted nodes (%d)').format(gone), _('Servers of this subscription that you deleted; updates do not import them again'), '',
					ui.createHandlerFn(view_, 'handleExcluded', section_id)), box.firstChild);
			box.insertBefore(upd, box.firstChild);
			return td;
		};
		/* new subscriptions: Auto request (curl, HAPP only when needed) */
		s.handleAdd = function(ev_, name) {
			const section_id = this.map.data.add(CONFIG, this.sectiontype);
			this.map.data.set(CONFIG, section_id, 'user_agent', 'auto');
			this.map.addedSection = section_id;
			return this.renderMoreOptionsModal(section_id);
		};

		o = s.option(form.Value, 'remark', _('Name'));
		o.rmempty = false;

		o = s.option(form.Value, 'url', _('Subscription URL'), _('The http:// or https:// link from your provider.'));
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

		/* Status: the result of the last update (subscribe.lua, rpcd
		 * "subscribe state"): Updating…, nodes received, or why it failed. */
		o = s.option(form.DummyValue, '_status', _('Status'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			return E('span', { 'id': 'ev-sub-' + section_id }, ev.subResultCell(section_id));
		};

		o = s.option(form.Flag, 'update_connected', _('Update only when connected'),
			_('Automatic updates run only while Easy VLESS is running. The Update button always runs.'));
		o.modalonly = true;

		o = s.option(form.Flag, 'hwid', _('HWID Support'),
			_('Send this router\'s stable hardware ID as the <code>X-HWID</code> header (with X-Device-OS / X-Ver-OS / X-Device-Model), for providers that limit devices. The ID is generated once and kept in /etc/easy_vless/hwid.'));
		o.modalonly = true;

		/* User-Agent: subscribe.lua sends option user_agent as the HTTP
		 * User-Agent header (unset/"curl" = curl's default, as before);
		 * "auto" (0.8.0): curl, and once more as HAPP only when the answer is
		 * an HTTP 4xx error or contains no supported node. */
		o = s.option(form.ListValue, '_ua_mode', _('User-Agent'),
			_('Auto: a normal request first; only if the provider answers with an error or without a supported node, one more request as the HAPP app. HAPP sends "User-Agent: HAPP" (for providers that serve the node list only to the HAPP app). Enable HWID Support as well if the provider limits devices.'));
		o.modalonly = true;
		o.value('auto', _('Auto (curl, then HAPP if needed)'));
		o.value('', _('Default (curl)'));
		o.value('HAPP', 'HAPP');
		o.value('custom', _('Custom'));
		o.cfgvalue = function(section_id) {
			const ua = uci.get(CONFIG, section_id, 'user_agent');
			if (!ua || ua == 'curl') return '';
			if (ua == 'auto') return 'auto';
			return ua == 'HAPP' ? 'HAPP' : 'custom';
		};
		o.write = function(section_id, value) {
			if (value == 'HAPP' || value == 'auto')
				uci.set(CONFIG, section_id, 'user_agent', value);
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

		o = s.option(form.Flag, 'auto_update', _('Automatic update'),
			_('Update this subscription periodically while Easy VLESS is started (cron).'));
		o.modalonly = true;

		o = s.option(form.ListValue, 'auto_update_interval', _('Update interval'),
			_('Time between automatic updates.'));
		o.modalonly = true;
		o.depends('auto_update', '1');
		[ 1, 2, 3, 4, 6, 8, 12, 24 ].forEach(function(h) { o.value(String(h), _('%d h').format(h)); });
		o.default = '24';

		o = s.option(form.ListValue, 'access_mode', _('Access method'),
			_('How the subscription is downloaded: directly, through the running proxy, or automatically.'));
		o.modalonly = true;
		o.value('', _('Auto'));
		o.value('direct', _('Direct'));
		o.value('proxy', _('Proxy'));

		o = s.option(form.Flag, 'allowInsecure', _('Allow insecure nodes'),
			_('Keep the allowInsecure flag of imported nodes (their TLS certificate is not verified). Off by default: such nodes are imported with certificate verification.'));
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
		ev.compactWhenEmpty(s, _('No URL Test groups. A group is optional: it switches automatically to the fastest of several servers.'));
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
		/* the server list may change without a page reload (subscription update) */
		o.load = function(section_id) {
			this.keylist = [];
			this.vallist = [];
			ev.servers().forEach(L.bind(function(srv) {
				this.value(srv['.name'], srv.remarks || srv['.name']);
			}, this));
			return form.MultiValue.prototype.load.apply(this, arguments);
		};
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
			if (ev.selectedNode() == section_id)
				return running ? ev.badge(_('Active'), 'ok') : ev.badge(_('Selected (stopped)'), 'idle');
			const refs = ev.references(section_id);
			return refs.length ? E('span', { 'title': refs.join(', ') }, _('Used by %d').format(refs.length)) : E('span', { 'style': 'opacity:.7' }, _('Inactive'));
		};

		this.viewState = Object.assign({ sort: 'default', status: 'all', source: 'all', text: '' }, readView());
		this.viewState.text = '';

		return m.render().then(L.bind(function(mapEl) {
			poll.add(L.bind(ev.refreshStatus, ev), 5);
			poll.add(L.bind(this.refreshLive, this), 10);
			poll.add(L.bind(this.refreshSubscriptions, this), 5);
			ev.onTestUpdate(L.bind(this.refreshRows, this));
			/* every save re-renders the map contents: keep the live URL Test
			 * panel, the sort order and the filters after such a re-render */
			const view_ = this, renderContents = m.renderContents;
			m.renderContents = function() {
				return renderContents.apply(this, arguments).then(function(el) {
					view_.placeLive(el);
					view_.refreshRows();
					view_.renderSubscriptionState();
					return el;
				});
			};
			const page = E('div', { 'id': 'ev-nodelist', 'class': 'ev-page' }, [
				ev.pageStyle(),
				this.style(),
				E('h2', {}, _('Node List')),
				ev.renderHeader(m, status, null, true, false),
				E('div', { 'class': 'cbi-map-descr' }, _('Servers: your VLESS servers - add one by hand or import a vless:// link, then Use it or test it. URL Subscriptions: a link from your provider that downloads the server list. URL Test Groups: several servers, sing-box uses the fastest one.')),
				E('div', { 'class': 'ev-toolbar' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-add', 'click': ui.createHandlerFn(this, 'handleImport') }, _('Import VLESS URL')),
					E('button', { 'class': 'btn cbi-button cbi-button-add', 'click': ui.createHandlerFn(this, function(ev_) {
						return this.serversSection.handleAdd(ev_);
					}) }, _('Add VLESS')),
					E('span', { 'id': 'ev-testall' }),
					E('button', { 'class': 'btn cbi-button cbi-button-negative', 'id': 'ev-delete-all', 'style': 'margin-left:auto',
						'title': _('Delete every server of the Node List (asks first and shows what else changes)'),
						'click': ui.createHandlerFn(this, 'handleDeleteAll') }, _('Delete all nodes'))
				]),
				this.renderViewBar(),
				this.placeLive(mapEl)
			]);
			window.setTimeout(L.bind(function() {
				this.refreshRows();
				this.renderSubscriptionState();
			}, this), 0);
			return page;
		}, this));
	},

	style: function() {
		return E('style', {}, [
			'.ev-toolbar, .ev-viewbar { display: flex; flex-wrap: wrap; gap: .4em; align-items: center; margin: .5em 0; }',
			'.ev-viewbar label { display: inline-flex; align-items: center; gap: .3em; white-space: nowrap; }',
			'.ev-viewbar select, .ev-viewbar input { width: auto; min-width: 0; max-width: 100%; }',
			'.ev-viewbar input[type=search] { width: 14em; height: auto; box-sizing: border-box; }',
			'.ev-sorted .ev-move { visibility: hidden; }',
			'.ev-test-btn.ev-busy { opacity: .55; cursor: progress; }',
			'#ev-shown { opacity: .7; font-size: 90%; }'
		].join('\n'));
	},

	/* Search, filters (test status, source) and sort order of the Servers
	 * table; the choice is remembered in this browser. */
	renderViewBar: function() {
		const v = this.viewState;
		const sel = function(id, label, value, options, onchange) {
			const s = E('select', { 'class': 'cbi-input-select', 'id': id, 'change': function() { onchange(s.value); } },
				options.map(function(o) { return E('option', { 'value': o[0], 'selected': o[0] == value ? '' : null }, o[1]); }));
			return E('label', {}, [ label, s ]);
		};
		const groups = [];
		ev.servers().forEach(function(s) {
			if (s.add_mode == '2' && s.group && groups.indexOf(s.group) < 0)
				groups.push(s.group);
		});
		if (v.source != 'all' && v.source != 'manual' && !groups.some(function(g) { return 'sub:' + g.toLowerCase() == v.source; }))
			v.source = 'all';
		return E('div', { 'class': 'ev-viewbar', 'id': 'ev-viewbar' }, [
			E('input', { 'type': 'search', 'class': 'cbi-input-text', 'id': 'ev-search',
				'placeholder': _('Search servers…'), 'title': _('Search by name, address or status'),
				'input': L.bind(function(e) { this.viewState.text = e.target.value; this.applyView(); }, this) }),
			sel('ev-filter-status', _('Show:'), v.status, [
				[ 'all', _('All') ], [ 'passed', _('Passed') ], [ 'failed', _('Failed') ], [ 'none', _('Not tested') ], [ 'testing', _('Testing') ]
			], L.bind(this.setView, this, 'status')),
			groups.length ? sel('ev-filter-source', _('Source:'), v.source,
				[ [ 'all', _('All') ], [ 'manual', _('Added manually') ] ].concat(groups.map(function(g) { return [ 'sub:' + g.toLowerCase(), g ]; })),
				L.bind(this.setView, this, 'source')) : '',
			sel('ev-sort', _('Sort:'), v.sort, [
				[ 'default', _('List order') ], [ 'latency', _('Latency') ], [ 'name', _('Name') ], [ 'status', _('Test result') ], [ 'time', _('Last test') ]
			], L.bind(this.setView, this, 'sort')),
			E('span', { 'id': 'ev-shown' })
		]);
	},

	handleSave: function() {
		return ev.handleSave(this.map);
	},

	handleSaveApply: function() {
		return ev.handleApply(this.map);
	}
});
