'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require poll';
'require easy_vless.common as ev';

/*
 * Easy VLESS - Rule Manage (PassWall2 "Rule Manage" + "Shunt Rule" model).
 * A rule (config shunt_rules) holds CONDITIONS only: protocol, inbound,
 * network, source, source port, port, domains, IPs. Its ACTION/target is a
 * shunt entry of the Main Router (main_router.<rule id>), chosen on Main (and
 * editable here as well - same UCI value). Rules are evaluated top to bottom
 * (UCI section order), exactly as util_sing-box.lua emits them.
 * Field formats are the ones util_sing-box.lua parses:
 *   protocol / inbound / source: space separated, network: "tcp,udp",
 *   port / sourcePort: comma separated ports or "from:to" ranges,
 *   domain_list / ip_list: one entry per line.
 */

const CONFIG = ev.CONFIG;
const ROUTER = ev.ROUTER;

/* Store a multi-value field as one space separated option (the runtime
 * parses a string, not a UCI list). */
function joinedList(o, sep) {
	o.cfgvalue = function(section_id) {
		const v = uci.get(CONFIG, section_id, this.option);
		if (Array.isArray(v))
			return v;
		return (v || '').split(sep == ',' ? /,/ : /\s+/).filter(function(x) { return x; });
	};
	o.write = function(section_id, value) {
		uci.set(CONFIG, section_id, this.option, L.toArray(value).join(sep));
	};
}

function summary(section_id) {
	const g = function(k) { return uci.get(CONFIG, section_id, k); };
	const parts = [];
	const d = ev.lines(g('domain_list')), i = ev.lines(g('ip_list'));
	if (d.length) parts.push(_('%d domains').format(d.length));
	if (i.length) parts.push(_('%d IPs').format(i.length));
	if (g('network') && g('network') != 'tcp,udp') parts.push(String(g('network')).toUpperCase());
	if (g('port')) parts.push(_('port %s').format(g('port')));
	if (g('sourcePort')) parts.push(_('source port %s').format(g('sourcePort')));
	if (g('source')) parts.push(_('source %s').format(L.toArray(g('source')).join(' ')));
	if (g('protocol')) parts.push(_('protocol %s').format(L.toArray(g('protocol')).join(' ')));
	if (g('inbound')) parts.push(_('inbound %s').format(L.toArray(g('inbound')).join(' ')));
	const geo = d.concat(i).filter(function(l) { return /^(geosite|geoip):/.test(l) && l != 'geoip:private'; }).length;
	if (geo) parts.push(_('%d geodata entries').format(geo));
	return parts.length ? parts.join(' · ') : _('no conditions (matches all)');
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(CONFIG),
			ev.callStatus()
		]);
	},

	handleMove: function(sid, up) {
		if (!ev.moveSection(sid, up))
			return Promise.resolve();
		return ev.saveAndCommit(this.map).catch(function() {});
	},

	render: function(data) {
		const status = data[1] || {};
		let m, s, o;
		const view_ = this;

		ev.ensureRouter();

		m = this.map = new form.Map(CONFIG);

		s = m.section(form.GridSection, 'shunt_rules', _('Shunt rules'),
			_('Rules are checked from top to bottom: the higher a rule, the higher its priority. A rule only describes conditions; its target is set on Main (Main Router entries) or here. A rule whose target is "Not used" is inactive.'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = false;
		s.nodescriptions = true;
		s.addbtntitle = _('Add rule');
		s.modaltitle = function(section_id) {
			return _('Shunt Rule') + ' » ' + (uci.get(CONFIG, section_id, 'remarks') || _('New rule'));
		};
		s.handleAdd = function(ev_, name) {
			/* Named section: the target is stored in main_router under the
			 * rule's section name, which must be stable across saves and
			 * reordering. */
			const section_id = this.map.data.add(CONFIG, this.sectiontype, ev.newName('rule_'));
			this.map.data.set(CONFIG, section_id, 'network', 'tcp,udp');
			this.map.addedSection = section_id;
			return this.renderMoreOptionsModal(section_id);
		};
		s.handleRemove = function(section_id, ev_) {
			uci.unset(CONFIG, ROUTER, section_id);
			return form.GridSection.prototype.handleRemove.apply(this, [ section_id, ev_ ]);
		};
		s.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, [ section_id ]);
			const box = td.lastElementChild;
			box.insertBefore(E('button', { 'class': 'btn cbi-button', 'title': _('Down'), 'click': ui.createHandlerFn(view_, 'handleMove', section_id, false) }, '↓'), box.firstChild);
			box.insertBefore(E('button', { 'class': 'btn cbi-button', 'title': _('Up'), 'click': ui.createHandlerFn(view_, 'handleMove', section_id, true) }, '↑'), box.firstChild);
			return td;
		};

		s.tab('main', _('Rule'));
		s.tab('match', _('Conditions'));

		o = s.taboption('main', form.Value, 'remarks', _('Name'));
		o.rmempty = false;

		o = s.taboption('main', form.DummyValue, '_order', _('Order'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			return String(ev.rules().findIndex(function(r) { return r['.name'] == section_id; }) + 1);
		};

		o = s.taboption('main', form.DummyValue, '_conditions', _('Conditions'));
		o.modalonly = false;
		o.textvalue = function(section_id) { return summary(section_id); };

		o = s.taboption('main', form.ListValue, '_target', _('Target'),
			_('Stored in the Main Router; also shown on Main. Takes effect while the Main Router is the main node.'));
		o.value('', _('Not used (rule off)'));
		ev.addTargetValues(o, true);
		o.cfgvalue = function(section_id) {
			return uci.get(CONFIG, ROUTER, section_id) || '';
		};
		o.write = function(section_id, value) {
			ev.ensureRouter();
			uci.set(CONFIG, ROUTER, section_id, value);
		};
		o.remove = function(section_id) {
			uci.unset(CONFIG, ROUTER, section_id);
		};
		o.textvalue = function(section_id) {
			const t = uci.get(CONFIG, ROUTER, section_id);
			return t ? ev.label(t) : E('em', {}, _('Not used'));
		};

		o = s.taboption('match', form.MultiValue, 'protocol', _('Protocol'),
			_('Sniffed protocol of the connection.'));
		o.modalonly = true;
		o.value('http', 'HTTP');
		o.value('tls', 'TLS');
		o.value('quic', 'QUIC');
		o.value('bittorrent', 'BitTorrent');
		joinedList(o, ' ');

		o = s.taboption('match', form.MultiValue, 'inbound', _('Inbound'),
			_('Transparent proxy = TPROXY/redirect traffic of LAN and router; SOCKS = the node SOCKS port (Settings → Other).'));
		o.modalonly = true;
		o.value('tproxy', _('Transparent proxy'));
		o.value('socks', _('SOCKS'));
		joinedList(o, ' ');

		o = s.taboption('match', form.ListValue, 'network', _('Network'));
		o.modalonly = true;
		o.value('tcp,udp', 'TCP UDP');
		o.value('tcp', 'TCP');
		o.value('udp', 'UDP');
		o.default = 'tcp,udp';

		o = s.taboption('match', form.DynamicList, 'source', _('Source'),
			_('IP <code>192.168.1.100</code>, CIDR <code>192.168.1.0/24</code> or <code>geoip:private</code>.'));
		o.modalonly = true;
		o.validate = function(section_id, value) {
			if (!value || value == 'geoip:private' || /^[0-9a-fA-F:.]+(\/\d{1,3})?$/.test(value))
				return true;
			return _('Expecting an IP address, a CIDR or geoip:private');
		};
		joinedList(o, ' ');

		o = s.taboption('match', form.Value, 'sourcePort', _('Source port'),
			_('Comma separated ports or ranges, e.g. <code>1000:2000,5000</code>.'));
		o.modalonly = true;
		o.validate = function(section_id, value) {
			return ev.validPorts(value) ? true : _('Expecting ports (1-65535) or ranges from:to separated by commas');
		};

		o = s.taboption('match', form.Value, 'port', _('Port'),
			_('Destination port(s), e.g. <code>443</code> or <code>1000:2000,8443</code>.'));
		o.modalonly = true;
		o.validate = function(section_id, value) {
			return ev.validPorts(value) ? true : _('Expecting ports (1-65535) or ranges from:to separated by commas');
		};

		o = s.taboption('match', form.TextValue, 'domain_list', _('Domain'),
			_('One entry per line:') + '<br/>' +
			_('<code>example.com</code> plain text: keyword, matches any domain containing it') + '<br/>' +
			_('<code>domain:example.com</code> the domain and its subdomains (recommended)') + '<br/>' +
			_('<code>full:www.example.com</code> exactly this domain') + '<br/>' +
			_('<code>regexp:\\.ru$</code> regular expression') + '<br/>' +
			_('<code>geosite:category</code> predefined list, needs the optional easy-vless-geodata package') + '<br/>' +
			_('Lines starting with # are comments.'));
		o.modalonly = true;
		o.rows = 8;
		o.validate = function(section_id, value) {
			const bad = ev.lines(value).filter(function(l) {
				const m = l.match(/^([a-z-]+):/);
				return m && [ 'domain', 'full', 'regexp', 'geosite', 'rule-set', 'rs' ].indexOf(m[1]) < 0;
			});
			return bad.length ? _('Unknown prefix: %s').format(bad[0]) : true;
		};

		o = s.taboption('match', form.TextValue, 'ip_list', _('IP'),
			_('One entry per line: IP <code>127.0.0.1</code>, CIDR <code>127.0.0.0/8</code>, <code>geoip:private</code> (built in) or <code>geoip:ru</code> (needs easy-vless-geodata). Lines starting with # are comments.'));
		o.modalonly = true;
		o.rows = 6;

		return m.render().then(L.bind(function(mapEl) {
			poll.add(L.bind(ev.refreshStatus, ev), 5);
			const shunt = ev.shuntEnabled();
			return E('div', {}, [
				E('h2', {}, _('Rule Manage')),
				ev.renderHeader(m, status, null, true),
				shunt ? '' : E('div', { 'class': 'alert-message' },
					E('p', {}, _('The main node is not the Main Router, so rules are currently not used. Select "Main Router (shunt)" as Node on Main to route by rules.'))),
				mapEl
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
