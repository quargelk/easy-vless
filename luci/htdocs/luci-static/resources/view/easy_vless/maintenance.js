'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require poll';
'require easy_vless.common as ev';

/*
 * Easy VLESS - Maintenance (0.9.0).
 *   Update             a newer release from GitHub; installed only after an
 *                      explicit confirmation (rpcd "update" -> update.sh:
 *                      verified download, compatibility check, configuration
 *                      copy, validation, rollback)
 *   Backup / Restore   the complete state of Easy VLESS as one file
 *   Import / Export    servers, rules or subscriptions as a file; import
 *                      only adds entries
 * Backup and Import are two formats (rpcd "transfer" -> backup.lua with
 * transfer.lua). A file is always checked on the router first and the result
 * shown; the configuration changes only after the user confirmed that
 * result. A refused file leaves everything as it was.
 */

/* strings are text, not HTML (see ev.E in common.js) */
const E = ev.E;
const CONFIG = ev.CONFIG;
const KINDS = [ 'nodes', 'rules', 'subscriptions' ];

function kindLabel(kind) {
	switch (kind) {
	case 'nodes': return _('Servers');
	case 'rules': return _('Rules');
	case 'subscriptions': return _('Subscriptions');
	}
	return kind;
}

/* Why a backup / import request was refused. */
function transferError(res) {
	if (res.rpc_error)
		return _('The router did not answer: %s').format(res.error);
	const e = res.error || {};
	switch (e.code) {
	case 'not_json':
		return _('This is not an Easy VLESS file (it is not valid JSON).');
	case 'not_backup':
		return e.kind
			? _('This is an export file (%s), not a backup. Use Import below for it.').format(kindLabel(e.kind))
			: _('This is not an Easy VLESS backup file.');
	case 'not_export':
		return e.backup
			? _('This is a backup of the whole configuration, not an export file. Use Restore above for it.')
			: _('This is not an Easy VLESS export file.');
	case 'version':
		return _('The file was made by a newer Easy VLESS (format %s). Update Easy VLESS first.').format(e.version);
	case 'too_large':
		return _('The file is too large.');
	case 'damaged':
		return _('The file is damaged or was changed after it was made (its checksum does not match). Nothing was changed.');
	case 'config_syntax':
		return _('The configuration in the backup is not valid (line %s). Nothing was changed.').format(e.line);
	case 'config_empty':
		return _('The backup contains an empty configuration. Nothing was changed.');
	case 'no_global':
		return _('The backup does not contain an Easy VLESS configuration. Nothing was changed.');
	case 'hwid':
		return _('The HWID in the backup is not valid. Nothing was changed.');
	case 'direct_ip':
		return _('The direct IP list in the backup contains an invalid entry (%s). Nothing was changed.').format(e.line);
	case 'busy':
		return e.what == 'subscription'
			? _('A subscription update is running; try again when it has finished.')
			: _('Easy VLESS is starting or stopping; try again when it has finished.');
	case 'rollback_copy':
		return _('The current configuration could not be saved before the restore (is the flash full?). Nothing was changed.');
	case 'apply':
		return e.restored === false
			? _('The restore failed (%s) and the previous configuration could not be put back automatically. Use "Undo the last restore".').format(e.step)
			: _('Writing the configuration failed (%s). The previous configuration is still in place.').format(e.step);
	case 'no_rollback':
		return _('There is no earlier configuration to go back to.');
	case 'kind':
		return _('The export file does not say what it contains.');
	case 'kind_mismatch':
		return _('The file contains %s, not %s.').format(kindLabel(e.kind), kindLabel(e.want));
	case 'items':
	case 'empty':
		return e.kind ? _('There is nothing to export: no %s.').format(kindLabel(e.kind)) : _('The file contains no entries.');
	case 'nothing':
		return _('Nothing to import: every entry of the file already exists or is invalid.');
	case 'no_config':
		return _('The configuration file of Easy VLESS could not be read.');
	case 'not_installed':
		return _('This function is not installed on the router (update the easy-vless package).');
	case 'interrupted':
		return _('The request was interrupted on the router. Nothing was changed; try again.');
	}
	return _('The router refused the request (%s).').format(e.detail || e.code || '?');
}

function skipReason(s) {
	switch (s.reason) {
	case 'exists': return _('already exists');
	case 'duplicate': return _('twice in the file');
	case 'invalid': return _('invalid value: %s').format(s.field);
	}
	return s.reason;
}

/* The translated headline of an update state; the router's own message
 * (what exactly happened) is shown below it. */
function updateHeadline(st) {
	switch (st.phase) {
	case 'download': return _('Downloading the release…');
	case 'verify': return st.status == 'failed' ? _('The release files did not pass the check. Nothing was installed.') : _('Verifying the release files…');
	case 'compatibility': return st.status == 'failed' ? _('This router does not meet the requirements of the new version. Nothing was installed.') : _('Checking the router for the new version…');
	case 'backup': return st.status == 'failed' ? _('The configuration could not be saved first. Nothing was installed.') : _('Saving the configuration…');
	case 'install': return _('Installing…');
	case 'validate': return _('Checking the installation…');
	case 'restart': return _('Restarting Easy VLESS…');
	case 'done': return _('Easy VLESS %s is installed.').format(st.version || '');
	case 'refused': return _('The update was not started.');
	case 'rolled_back': return _('The update failed and was rolled back: Easy VLESS %s is installed again, with the saved configuration.').format(st.version || '');
	case 'rollback_failed': return _('The update failed, and the previous version could not be put back completely.');
	}
	return st.phase || '';
}

function updateError(res) {
	if (res.rpc_error)
		return _('The router did not answer: %s').format(res.error);
	switch (res.error) {
	case 'network':
		return _('GitHub could not be reached over HTTPS, so it is not known whether there is a newer version. Check the internet connection and the router time.');
	case 'release':
		return _('The latest release on GitHub does not look like an Easy VLESS release (%s). Nothing is offered.').format(res.detail || '');
	case 'not_installed':
		return res.current === undefined
			? _('The update function is not installed on the router.')
			: _('Easy VLESS is not installed as a package on this router, so it cannot be updated from here.');
	case 'busy':
		return _('An update is already running.');
	}
	return _('The router refused the request (%s).').format(res.detail || res.error || '?');
}

function updateFinished(st) {
	return !st || [ 'done', 'refused', 'rolled_back', 'rollback_failed' ].indexOf(st.phase) > -1 || st.status == 'failed';
}

return view.extend({
	/* pure helpers (tests/maintenance-view-test.js) */
	transferError: transferError,
	skipReason: skipReason,
	updateHeadline: updateHeadline,
	updateError: updateError,
	updateFinished: updateFinished,

	load: function() {
		return Promise.all([ uci.load(CONFIG), ev.callStatus(), ev.callUpdate('state'), ev.callTransfer('state') ]);
	},

	note: function(box, kind, text, extra) {
		dom.content(box, E('div', { 'class': 'alert-message ' + (kind == 'ok' ? 'success' : (kind == 'bad' ? 'error' : 'warning')) }, [ E('p', {}, text) ].concat(extra || [])));
	},

	readFile: function(inputId) {
		const input = document.getElementById(inputId);
		const file = input && input.files && input.files[0];
		if (!file)
			return Promise.resolve(null);
		return new Promise(function(resolve, reject) {
			const r = new FileReader();
			r.onload = function() { resolve(String(r.result)); };
			r.onerror = function() { reject(new Error(_('The file could not be read.'))); };
			r.readAsText(file);
		});
	},

	/* ---------- update ---------- */

	renderUpdate: function(check) {
		const box = document.getElementById('ev-update');
		if (!box)
			return;
		if (!check) {
			dom.content(box, E('p', {}, E('em', {}, _('Not checked yet.'))));
			return;
		}
		if (!check.ok) {
			this.note(box, 'warn', updateError(check));
			return;
		}
		if (!check.available) {
			dom.content(box, E('p', {}, [ ev.badge(_('Up to date'), 'ok'), ' ', _('Easy VLESS %s is the latest version.').format(check.current) ]));
			return;
		}
		dom.content(box, E('div', { 'class': 'alert-message notice' }, [
			E('p', {}, [ E('strong', {}, _('A new version of Easy VLESS is available: %s').format(check.latest)), ' ',
				E('small', { 'style': 'opacity:.75' }, _('(installed: %s)').format(check.current)) ]),
			E('button', { 'class': 'btn cbi-button cbi-button-action', 'id': 'ev-update-btn', 'click': ui.createHandlerFn(this, 'handleUpdate', check) }, _('Update')),
			' ',
			E('button', { 'class': 'btn cbi-button', 'click': L.bind(function() {
				ev.setUpdateDismissed(check.latest);
				dom.content(box, E('p', {}, _('Not now. Version %s stays available here.').format(check.latest)));
			}, this) }, _('Later'))
		]));
	},

	handleCheck: function() {
		const box = document.getElementById('ev-update');
		dom.content(box, E('p', { 'class': 'spinning' }, _('Asking GitHub for the latest release…')));
		return ev.callUpdate('recheck').then(L.bind(this.renderUpdate, this));
	},

	handleUpdate: function(check) {
		const body = E('div', {}, [
			E('p', {}, _('Update Easy VLESS %s to %s?').format(check.current, check.latest)),
			E('ul', {}, [
				_('The release files are downloaded over HTTPS and checked against the checksums of the release; a file that does not match is not installed.'),
				_('The router is checked for the new version before anything is changed.'),
				_('Your configuration is kept; a copy is saved first.'),
				_('Easy VLESS is restarted at the end if its main switch is on: connections are interrupted for a moment.'),
				_('If the installation or the check afterwards fails, the previous version and configuration are put back.')
			].map(function(t) { return E('li', {}, t); }))
		]);
		return ev.confirm(_('Update'), body, _('Update')).then(L.bind(function(ok) {
			if (!ok)
				return;
			return ev.exclusive(_('Update'), L.bind(function() {
				ev.showBusy(_('Update'), _('Starting the update…'));
				let before = null;
				/* the state of an earlier update must not be taken for this one */
				return ev.callUpdate('state').then(function(old) {
					before = (old && old.ok && old.state) ? old.state.time : null;
					return ev.callUpdate('install', check.tag);
				}).then(L.bind(function(res) {
					if (!res.ok) {
						ev.showResult(_('Update'), 'bad', _('The update was not started.'), updateError(res));
						return;
					}
					return this.waitUpdate(before);
				}, this));
			}, this));
		}, this));
	},

	/* Poll the update state. rpcd restarts during the package upgrade, so a
	 * failed request only means "ask again". before = the time stamp of the
	 * state that was there before this update was started (it is not the
	 * result of this one); give up after 10 minutes. */
	waitUpdate: function(before) {
		const t0 = Date.now();
		const step = L.bind(function() {
			return ev.sleep(2500).then(function() { return ev.callUpdate('state'); }).then(L.bind(function(res) {
				const st = (res && res.ok) ? res.state : null;
				const fresh = st && st.time !== before;
				if (fresh && !res.busy && updateFinished(st)) {
					if (st.phase == 'done')
						ev.showResult(_('Update'), 'ok', updateHeadline(st), st.message, E('p', {},
							E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': function() { window.location.reload(); } }, _('Reload the page'))));
					else
						ev.showResult(_('Update'), st.phase == 'rolled_back' ? 'warn' : 'bad', updateHeadline(st), (st.message || '') + '\n\n' + (res.log || ''));
					return;
				}
				if (res && res.ok && !res.busy && !fresh && Date.now() - t0 > 30000) {
					ev.showResult(_('Update'), 'bad', _('The update was not started.'), _('The router did not begin the update. Try again; the update log is /tmp/log/easy_vless_update.log on the router.'));
					return;
				}
				if (Date.now() - t0 > 600000) {
					ev.showResult(_('Update'), 'bad', _('The update did not finish in time.'), _('Reload the page and look at the state here; the update log is /tmp/log/easy_vless_update.log on the router.'));
					return;
				}
				if (fresh)
					ev.showBusy(_('Update'), updateHeadline(st));
				return step();
			}, this));
		}, this);
		return step();
	},

	handleAutoCheck: function(ev_) {
		const on = ev_.target.checked;
		return ev.exclusive(_('Save'), function() {
			uci.set(CONFIG, 'global', 'update_check', on ? '1' : '0');
			return ev.saveAndCommit(null).then(function() {
				ev.notify(on ? _('Easy VLESS looks for a new version when its pages are opened, at most once a day.')
					: _('Easy VLESS no longer looks for new versions by itself. "Check for updates" still works.'));
			});
		});
	},

	/* ---------- backup / restore ---------- */

	handleBackup: function() {
		return ev.callTransfer('backup').then(L.bind(function(res) {
			const box = document.getElementById('ev-backup-result');
			if (!res.ok)
				return this.note(box, 'bad', transferError(res));
			ev.downloadText(res.filename, res.content);
			this.note(box, 'ok', _('Backup saved as %s. It contains your server credentials and subscription links: keep it private.').format(res.filename));
		}, this));
	},

	handleRestoreCheck: function() {
		const box = document.getElementById('ev-backup-result');
		return this.readFile('ev-restore-file').then(L.bind(function(text) {
			if (text == null)
				return this.note(box, 'warn', _('Choose a backup file first.'));
			dom.content(box, E('p', { 'class': 'spinning' }, _('Checking the file…')));
			return ev.callTransfer('restore_check', text).then(L.bind(function(res) {
				if (!res.ok)
					return this.note(box, 'bad', transferError(res));
				const s = res.summary || {};
				const items = [
					_('Servers: %d · URL Test groups: %d · rules: %d · subscriptions: %d').format(s.servers || 0, s.groups || 0, s.rules || 0, s.subscriptions || 0),
					s.created ? _('Made: %s').format(new Date(s.created * 1000).toLocaleString()) + (s.app_version ? ' · Easy VLESS ' + s.app_version : '') + (s.hostname ? ' · ' + s.hostname : '') : null,
					s.enabled ? _('Main switch: on - Easy VLESS is restarted with the restored configuration.') : _('Main switch: off - Easy VLESS is stopped after the restore.')
				].filter(function(x) { return x; });
				ev.arr(res.warnings).forEach(function(w) {
					if (w.code == 'dangling')
						items.push('⚠️ ' + _('In this backup these entries point to a node that does not exist: %s. Choose their target after the restore.').format(w.items));
				});
				this.note(box, 'warn', _('The file is a valid backup. Restoring it replaces the whole current configuration of Easy VLESS:'), [
					E('ul', {}, items.map(function(t) { return E('li', {}, t); })),
					E('button', { 'class': 'btn cbi-button cbi-button-negative', 'id': 'ev-restore-apply',
						'click': ui.createHandlerFn(this, 'handleRestoreApply', text) }, _('Restore this backup'))
				]);
			}, this));
		}, this)).catch(L.bind(function(e) { this.note(box, 'bad', e.message); }, this));
	},

	/* The service is stopped or restarted detached after a restore / rollback. */
	afterReplace: function(res, done) {
		const box = document.getElementById('ev-backup-result');
		ev.showBusy(_('Restore'), res.service == 'restart' ? _('Restarting Easy VLESS with the restored configuration…') : _('Stopping Easy VLESS…'));
		return ev.waitIdle(0, 60000).then(L.bind(function() {
			ui.hideModal();
			uci.unload(CONFIG);
			return uci.load(CONFIG);
		}, this)).then(L.bind(function() {
			ev.refreshStatus();
			this.note(box, 'ok', done);
			this.renderRollback(!!res.rollback);
		}, this));
	},

	handleRestoreApply: function(text) {
		return ev.confirm(_('Restore'), _('Replace the whole configuration of Easy VLESS with this backup? The current configuration is kept as a copy: "Undo the last restore" puts it back.'), _('Restore')).then(L.bind(function(ok) {
			if (!ok)
				return;
			return ev.exclusive(_('Restore'), L.bind(function() {
				ev.showBusy(_('Restore'), _('Restoring the configuration…'));
				return ev.callTransfer('restore_apply', text).then(L.bind(function(res) {
					if (!res.ok) {
						ui.hideModal();
						return this.note(document.getElementById('ev-backup-result'), 'bad', transferError(res));
					}
					return this.afterReplace(res, _('The backup was restored.'));
				}, this));
			}, this));
		}, this));
	},

	handleRollback: function() {
		return ev.confirm(_('Undo the last restore'), _('Put back the configuration from before the last restore?'), _('Undo the last restore')).then(L.bind(function(ok) {
			if (!ok)
				return;
			return ev.exclusive(_('Restore'), L.bind(function() {
				return ev.callTransfer('rollback').then(L.bind(function(res) {
					if (!res.ok)
						return this.note(document.getElementById('ev-backup-result'), 'bad', transferError(res));
					return this.afterReplace(res, _('The configuration from before the restore is back.'));
				}, this));
			}, this));
		}, this));
	},

	renderRollback: function(available, time) {
		const el = document.getElementById('ev-rollback');
		if (!el)
			return;
		dom.content(el, available ? E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleRollback'),
			'title': time ? new Date(time * 1000).toLocaleString() : '' }, _('Undo the last restore')) : '');
	},

	/* ---------- import / export ---------- */

	handleExport: function(kind) {
		return ev.callTransfer('export', '', kind).then(L.bind(function(res) {
			const box = document.getElementById('ev-import-result');
			if (!res.ok)
				return this.note(box, 'warn', transferError(res));
			ev.downloadText(res.filename, res.content);
			this.note(box, 'ok', (kind == 'rules'
				? _('%d rule(s) exported to %s. A rule keeps its target only when it is Direct, Block or "Default target".')
				: kind == 'nodes' ? _('%d server(s) exported to %s. The file contains the server credentials: keep it private.')
				: _('%d subscription(s) exported to %s. The file contains the subscription links: keep it private.')).format(res.count, res.filename));
		}, this));
	},

	handleImportCheck: function() {
		const box = document.getElementById('ev-import-result');
		return this.readFile('ev-import-file').then(L.bind(function(text) {
			if (text == null)
				return this.note(box, 'warn', _('Choose an export file first.'));
			dom.content(box, E('p', { 'class': 'spinning' }, _('Checking the file…')));
			return ev.callTransfer('import_check', text).then(L.bind(function(res) {
				if (!res.ok)
					return this.note(box, 'bad', transferError(res));
				const skipped = ev.arr(res.skipped);
				const parts = [
					E('p', {}, _('%s: %d to add, %d skipped.').format(kindLabel(res.kind), res.count || 0, skipped.length)),
					ev.arr(res.names).length ? E('p', {}, E('small', {}, ev.arr(res.names).join(', '))) : '',
					skipped.length ? E('ul', {}, skipped.slice(0, 50).map(function(s) { return E('li', {}, '%s — %s'.format(s.name, skipReason(s))); })) : '',
					res.dropped ? E('p', {}, E('small', {}, _('%d option(s) that Easy VLESS does not know were left out.').format(res.dropped))) : ''
				];
				if (res.count > 0)
					parts.push(E('button', { 'class': 'btn cbi-button cbi-button-action', 'id': 'ev-import-apply',
						'click': ui.createHandlerFn(this, 'handleImportApply', text) }, _('Add %d').format(res.count)));
				this.note(box, res.count > 0 ? 'warn' : 'bad', res.count > 0
					? _('The file was checked. Importing only adds entries; nothing that exists is changed:')
					: _('Nothing to import: every entry of the file already exists or is invalid.'), parts);
			}, this));
		}, this)).catch(L.bind(function(e) { this.note(box, 'bad', e.message); }, this));
	},

	handleImportApply: function(text) {
		return ev.exclusive(_('Import'), L.bind(function() {
			return ev.callTransfer('import_apply', text).then(L.bind(function(res) {
				const box = document.getElementById('ev-import-result');
				if (!res.ok)
					return this.note(box, 'bad', transferError(res));
				uci.unload(CONFIG);
				return uci.load(CONFIG).then(L.bind(function() {
					this.note(box, 'ok', (res.kind == 'rules'
						? _('%d rule(s) added at the end of the rule list. Check their order and targets in Rule Manage; they apply after Save & Apply on Main.')
						: res.kind == 'nodes' ? _('%d server(s) added to the Node List.')
						: _('%d subscription(s) added. Press Update in Node List to download their servers.')).format(res.added));
				}, this));
			}, this));
		}, this));
	},

	render: function(data) {
		const status = data[1] || {};
		const upd = data[2] || {};
		const tr = data[3] || {};
		ev.lastStatus = status;
		const running = upd.ok && upd.busy;

		poll.add(L.bind(ev.refreshStatus, ev), 5);
		const page = E('div', { 'class': 'ev-page' }, [
			ev.pageStyle(),
			E('style', {}, '.ev-row { display: flex; flex-wrap: wrap; gap: .5em; align-items: center; margin: .5em 0; } .ev-row input[type=file] { max-width: 100%; }'),
			E('h2', {}, _('Maintenance')),
			ev.renderHeader(null, status, null, true, false),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Update')),
				E('div', { 'class': 'cbi-section-descr' }, _('Easy VLESS never updates itself: a new version is only shown here, and installed when you press Update and confirm.')),
				E('div', { 'id': 'ev-update' }),
				E('div', { 'class': 'ev-row' }, [
					E('button', { 'class': 'btn cbi-button', 'id': 'ev-update-check', 'click': ui.createHandlerFn(this, 'handleCheck') }, _('Check for updates')),
					E('label', {}, [
						E('input', { 'type': 'checkbox', 'id': 'ev-update-auto', 'checked': ev.updateCheckEnabled() ? '' : null,
							'change': ui.createHandlerFn(this, 'handleAutoCheck') }), ' ',
						_('Look for a new version when a page of Easy VLESS is opened (the router asks GitHub at most once a day)') ])
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Backup and restore')),
				E('div', { 'class': 'cbi-section-descr' }, _('The complete state of Easy VLESS in one file: settings, servers, rules, subscriptions, the subscription HWID. Restore replaces the whole configuration with the file.')),
				E('div', { 'class': 'ev-row' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'id': 'ev-backup-btn', 'click': ui.createHandlerFn(this, 'handleBackup') }, _('Download backup')) ]),
				E('div', { 'class': 'ev-row' }, [
					E('input', { 'type': 'file', 'id': 'ev-restore-file', 'accept': '.json,application/json' }),
					E('button', { 'class': 'btn cbi-button', 'id': 'ev-restore-check', 'click': ui.createHandlerFn(this, 'handleRestoreCheck') }, _('Check the file…')),
					E('span', { 'id': 'ev-rollback' })
				]),
				E('div', { 'id': 'ev-backup-result' })
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Import and export')),
				E('div', { 'class': 'cbi-section-descr' }, _('Single kinds of entries, to carry them to another router: servers, rules or subscriptions. Import only adds what is not there yet; it never changes existing entries or settings.')),
				E('div', { 'class': 'ev-row' }, [ E('span', {}, _('Export:')) ].concat(KINDS.map(L.bind(function(kind) {
					return E('button', { 'class': 'btn cbi-button', 'id': 'ev-export-' + kind, 'click': ui.createHandlerFn(this, 'handleExport', kind) }, kindLabel(kind));
				}, this)))),
				E('div', { 'class': 'ev-row' }, [
					E('span', {}, _('Import:')),
					E('input', { 'type': 'file', 'id': 'ev-import-file', 'accept': '.json,application/json' }),
					E('button', { 'class': 'btn cbi-button', 'id': 'ev-import-check', 'click': ui.createHandlerFn(this, 'handleImportCheck') }, _('Check the file…'))
				]),
				E('div', { 'id': 'ev-import-result' })
			])
		]);

		window.setTimeout(L.bind(function() {
			this.renderRollback(!!tr.rollback, tr.rollback_time);
			if (running) {
				/* an update started before this page was opened is still running */
				ev.showBusy(_('Update'), updateHeadline(upd.state || {}));
				ev.exclusive(_('Update'), L.bind(this.waitUpdate, this, null));
			}
			else {
				this.renderUpdate(upd.ok ? upd.check : null);
				if (upd.ok && upd.state && upd.state.status == 'failed') {
					const box = document.getElementById('ev-update');
					box.insertBefore(E('div', { 'class': 'alert-message warning' }, [
						E('p', {}, E('strong', {}, _('Last update: %s').format(updateHeadline(upd.state)))),
						E('p', {}, E('small', {}, upd.state.message || '')) ]), box.firstChild);
				}
			}
		}, this), 0);
		return page;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
