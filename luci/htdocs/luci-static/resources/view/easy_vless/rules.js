'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require poll';
'require easy_vless.common as ev';

/*
 * Easy VLESS - Routing rules (routing_mode=singbox).
 * Rules are the existing PassWall2-derived "shunt" model: shunt_rules
 * sections evaluated in order by sing-box, each with a target stored in the
 * router node (main_router.<rule id>). Traffic matching no rule uses the
 * default outbound (main_router.default_node).
 * geoip:/geosite: entries need the optional easy-vless-geodata package; the
 * runtime refuses to start with a clear message when it is missing.
 */

const CONFIG = ev.CONFIG;
const ROUTER = ev.ROUTER;

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(CONFIG),
			ev.callStatus().catch(function() { return {}; })
		]);
	},

	/* Saved immediately (like "Make active"), then the page is reloaded. */
	handleToggle: function(enable) {
		ev.setRulesEnabled(enable);
		return ev.applyIfRunning(this.map).then(function() {
			window.setTimeout(function() { window.location.reload(); }, 500);
		});
	},

	render: function(data) {
		const status = data[1] || {};
		let m, s, o;

		m = this.map = new form.Map(CONFIG, _('Easy VLESS - Routing rules'),
			_('Without rules all traffic goes through the active server or group. With rules enabled, matching traffic goes to the rule target and everything else to the default outbound. Rules are checked from top to bottom.'));

		if (ev.rulesEnabled()) {
			s = m.section(form.NamedSection, 'global', 'global');
			s.anonymous = true;

			/* Default outbound = main_router.default_node while rules are on;
			 * the same value "Make active" sets on the Servers page. */
			o = s.option(form.ListValue, '_default_target', _('Default outbound'),
				_('Traffic that matches no rule.'));
			ev.addTargetValues(o, true);
			o.cfgvalue = function() {
				return ev.activeTarget() || '_direct';
			};
			o.write = function(section_id, value) {
				ev.setActiveTarget(value);
			};
		}

		s = m.section(form.GridSection, 'shunt_rules', _('Rule list'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add rule');
		s.modaltitle = function(section_id) {
			return _('Rule') + ' » ' + (uci.get(CONFIG, section_id, 'remarks') || _('New rule'));
		};
		s.handleAdd = function(ev_, name) {
			/* Named section: the target is stored in main_router under the
			 * rule's section name, which must be stable across the save. */
			const section_id = this.map.data.add(CONFIG, this.sectiontype, ev.newName('rule_'));
			ev.ensureRouter();
			this.map.data.set(CONFIG, ROUTER, section_id, '_direct');
			this.map.addedSection = section_id;
			return this.renderMoreOptionsModal(section_id);
		};

		o = s.option(form.Value, 'remarks', _('Name'));
		o.rmempty = false;

		o = s.option(form.ListValue, '_target', _('Target'));
		o.value('_direct', _('Direct (no proxy)'));
		o.value('_default', _('Default outbound'));
		o.value('_blackhole', _('Block'));
		ev.servers().forEach(function(srv) { o.value(srv['.name'], ev.label(srv['.name'])); });
		ev.groups().forEach(function(g) { o.value(g['.name'], ev.label(g['.name'])); });
		o.cfgvalue = function(section_id) {
			return uci.get(CONFIG, ROUTER, section_id) || '_direct';
		};
		o.write = function(section_id, value) {
			ev.ensureRouter();
			uci.set(CONFIG, ROUTER, section_id, value);
		};
		o.remove = function(section_id) {
			uci.unset(CONFIG, ROUTER, section_id);
		};

		o = s.option(form.TextValue, 'domain_list', _('Domains'),
			_('One entry per line: <code>domain:example.com</code> (domain and subdomains), <code>full:www.example.com</code> (exact), <code>regexp:...</code>, a plain word matches as keyword. <code>geosite:ru</code> needs easy-vless-geodata.'));
		o.rows = 6;
		o.modalonly = true;
		o.textvalue = function(section_id) {
			const v = (this.cfgvalue(section_id) || '').split(/\n/).filter(function(l) { return l.trim() && l.charAt(0) != '#'; });
			return v.length ? _('%d domain entries').format(v.length) : '-';
		};

		o = s.option(form.TextValue, 'ip_list', _('IP addresses'),
			_('One IP or CIDR per line, e.g. <code>192.0.2.0/24</code>. <code>geoip:private</code> is built in; other <code>geoip:</code> codes need easy-vless-geodata.'));
		o.rows = 4;
		o.modalonly = true;

		o = s.option(form.DummyValue, '_summary', _('Matches'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const count = function(opt) {
				return (uci.get(CONFIG, section_id, opt) || '').split(/\n/).filter(function(l) { return l.trim() && l.charAt(0) != '#'; });
			};
			const d = count('domain_list'), i = count('ip_list');
			const geo = d.concat(i).filter(function(l) { return /^(geosite|geoip):/.test(l) && l != 'geoip:private'; }).length;
			let t = _('%d domains, %d IPs').format(d.length, i.length);
			if (geo)
				t += ' ' + _('(%d geodata entries)').format(geo);
			return t;
		};

		o = s.option(form.ListValue, 'network', _('Network'));
		o.value('tcp,udp', _('TCP and UDP'));
		o.value('tcp', 'TCP');
		o.value('udp', 'UDP');
		o.default = 'tcp,udp';
		o.modalonly = true;

		o = s.option(form.Value, 'port', _('Destination ports'), _('Optional, e.g. <code>443</code> or <code>1000:2000</code>, comma separated.'));
		o.modalonly = true;
		o.validate = function(section_id, value) {
			if (value && !/^\d+(:\d+)?(,\d+(:\d+)?)*$/.test(value))
				return _('Expecting ports or ranges separated by commas');
			return true;
		};

		const enabled = ev.rulesEnabled();
		const toggle = E('div', { 'class': 'cbi-section' }, [
			E('p', {}, enabled
				? E('strong', { 'style': 'color:#2e7d32' }, _('Routing rules are enabled.'))
				: E('strong', {}, _('Routing rules are disabled: all traffic uses the active server or group.'))),
			E('button', {
				'class': 'btn cbi-button ' + (enabled ? 'cbi-button-reset' : 'cbi-button-apply'),
				'click': ui.createHandlerFn(this, 'handleToggle', !enabled)
			}, enabled ? _('Disable routing rules') : _('Enable routing rules'))
		]);

		return m.render().then(L.bind(function(mapEl) {
			poll.add(L.bind(ev.refreshStatus, ev), 5);
			return E('div', {}, [ ev.renderHeader(m, status), toggle, mapEl ]);
		}, this));
	}
});
