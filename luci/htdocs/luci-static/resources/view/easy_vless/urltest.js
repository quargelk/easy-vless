'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require poll';
'require dom';
'require easy_vless.common as ev';

/*
 * Easy VLESS - URL Test groups.
 * A group is a sing-box "urltest" outbound (util_sing-box.lua
 * gen_urltest_outbound): sing-box itself probes the members and uses the
 * fastest one. Results come from the Clash API of the running sing-box
 * (experimental.clash_api), so they exist only while Easy VLESS is running
 * and the group is part of the running configuration.
 */

const CONFIG = ev.CONFIG;
let lastGroups = null;
let lastError = null;
let lastTested = {};

/* sing-box keeps only successful results in its history (a failed test
 * deletes the entry), so "no result" means not tested yet or unreachable.
 * Failures of the last manual test are remembered here. */
function delayText(d, tested) {
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
			ev.callStatus().catch(function() { return {}; }),
			ev.callGroups().catch(function() { return {}; })
		]);
	},

	setGroups: function(res) {
		if (res && res.ok) {
			lastGroups = res.groups || [];
			lastError = null;
		}
		else {
			lastGroups = null;
			lastError = (res && res.error) || _('No data');
		}
	},

	renderResults: function() {
		const groups = ev.groups();
		if (!groups.length)
			return E('p', {}, _('No URL Test groups yet.'));

		if (!lastGroups)
			return E('div', { 'class': 'alert-message' }, [
				E('p', {}, _('No live results: %s').format(lastError || '')),
				E('p', {}, _('Results come from the running sing-box. Make a group active (or use it in a routing rule) and start Easy VLESS.'))
			]);

		return E('div', {}, groups.map(L.bind(function(g) {
			const id = g['.name'];
			const live = lastGroups.filter(function(x) { return x.id == id; })[0];
			const title = E('h4', {}, ev.label(id));
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
						E('td', { 'class': 'td' }, mem.id ? ev.label(mem.id) : mem.tag),
						E('td', { 'class': 'td' }, delayText(mem.delay, lastTested[mem.tag])),
						E('td', { 'class': 'td' }, (live.now == mem.tag) ? E('strong', {}, '●') : ''),
						E('td', { 'class': 'td right' }, mem.id ? E('button', {
							'class': 'btn cbi-button',
							'title': _('Stop using the group and make this server the active one'),
							'click': ui.createHandlerFn(this, 'handleUseServer', mem.id)
						}, _('Use this server')) : '')
					]);
				}, this)))),
				E('div', {}, E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleTest', id)
				}, _('Test all servers now')))
			]);
		}, this)));
	},

	refreshResults: function() {
		return ev.callGroups().then(L.bind(function(res) {
			this.setGroups(res);
			const box = document.getElementById('ev-urltest-results');
			if (box)
				dom.content(box, this.renderResults());
		}, this));
	},

	handleTest: function(id) {
		return ev.callGroupTest(id).then(L.bind(function(res) {
			if (!res.ok)
				ev.showResult(_('URL Test'), false, res.error);
			this.setGroups(res.ok ? res : null);
			lastTested = {};
			L.toArray(res.tested).forEach(function(t) { lastTested[t.tag] = t; });
			if (!res.ok)
				lastError = res.error;
			const box = document.getElementById('ev-urltest-results');
			if (box)
				dom.content(box, this.renderResults());
		}, this));
	},

	handleUseServer: function(sid) {
		ev.setActiveTarget(sid);
		return ev.applyIfRunning(this.map);
	},

	handleMakeActive: function(sid) {
		ev.setActiveTarget(sid);
		return ev.applyIfRunning(this.map);
	},

	render: function(data) {
		const status = data[1] || {};
		this.setGroups(data[2]);
		let m, s, o;
		const view_ = this;

		m = this.map = new form.Map(CONFIG, _('Easy VLESS - URL Test'),
			_('A URL Test group lets sing-box probe its servers periodically and use the fastest one. Make a group active or use it as a routing rule target.'));

		s = m.section(form.GridSection, 'nodes');
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
			this.map.addedSection = section_id;
			return this.renderMoreOptionsModal(section_id);
		};
		s.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, [ section_id ]);
			td.lastElementChild.insertBefore(E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'disabled': (ev.activeTarget() == section_id) ? '' : null,
				'click': ui.createHandlerFn(view_, 'handleMakeActive', section_id)
			}, _('Make active')), td.lastElementChild.firstChild);
			return td;
		};

		o = s.option(form.Value, 'remarks', _('Name'));
		o.rmempty = false;

		o = s.option(form.MultiValue, 'urltest_node', _('Servers'));
		o.rmempty = false;
		ev.servers().forEach(function(srv) {
			o.value(srv['.name'], ev.label(srv['.name']));
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
			_('Use an https:// URL: for manual tests ("Test all servers now") sing-box ignores http:// URLs and uses its default URL.'));
		o.placeholder = 'https://x.com';
		o.default = 'https://x.com';
		o.rmempty = false;
		o.modalonly = true;
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
			return (ev.activeTarget() == section_id) ? E('strong', { 'style': 'color:#2e7d32' }, '● ' + _('Active')) : '-';
		};

		return m.render().then(L.bind(function(mapEl) {
			poll.add(L.bind(ev.refreshStatus, ev), 5);
			poll.add(L.bind(this.refreshResults, this), 10);
			return E('div', {}, [
				ev.renderHeader(m, status),
				mapEl,
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('Live results')),
					E('div', { 'id': 'ev-urltest-results' }, this.renderResults())
				])
			]);
		}, this));
	}
});
