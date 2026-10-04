'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require dom';
'require poll';
'require easy_vless.common as ev';
'require easy_vless.rulecheck as rc';

/*
 * Easy VLESS - Rule Manage (PassWall2 "Rule Manage" + "Shunt Rule" model).
 *
 * A rule (config shunt_rules) = NAME + ORDER + CONDITIONS + ACTION/TARGET.
 *   Conditions are the fields util_sing-box.lua really turns into a sing-box
 *   route rule: domain_resource (prepared resource ids, UCI list),
 *   domain_list, ip_list, network, port, source, sourcePort, protocol,
 *   inbound. Formats are the ones the runtime parses: protocol / inbound /
 *   source space separated, network "tcp,udp" | "tcp" | "udp", ports comma
 *   separated with from:to ranges, domain_list / ip_list one entry per line.
 *   Action/target = main_router.<rule id> (also selectable on Main).
 *   Order = UCI section order = sing-box rule order (first match wins).
 * Resources come from /usr/share/easy_vless/resources/manifest.json (rpcd
 * "resources"); UCI keeps only their ids, the runtime reads the files.
 * Checks (0.9.0, easy_vless/rulecheck.js): rules that can never apply, are
 * covered by an earlier rule, conflict with it or point to a missing target
 * are marked in the list - only what follows from the settings is claimed.
 */

/* strings are text, not HTML (see ev.E in common.js) */
const E = ev.E;
const CONFIG = ev.CONFIG;
const ROUTER = ev.ROUTER;
let RESOURCES = [];        /* [{ id, name, type, entries, exists, path }] */
let TEMPLATES = [];        /* prepared rule templates from the manifest */

const COND_TYPES = [
	{ type: 'domain_resource', label: _('Domain Resource'), kind: 'resources' },
	{ type: 'domain_list', label: _('Domain (manual)'), kind: 'textarea',
	  help: _('One per line. <code>domain:example.com</code> domain + subdomains · <code>full:www.example.com</code> exact · <code>regexp:\\.ru$</code> regular expression · plain text = keyword (matches any domain containing it) · <code>geosite:name</code> needs easy-vless-geodata · # comment') },
	{ type: 'ip_list', label: _('IP'), kind: 'textarea',
	  help: _('One per line: IP, CIDR (<code>10.0.0.0/8</code>), <code>geoip:private</code> (built in) or <code>geoip:ru</code> (needs easy-vless-geodata).') },
	{ type: 'network', label: _('Network'), kind: 'select', values: [ [ 'tcp', 'TCP' ], [ 'udp', 'UDP' ] ] },
	{ type: 'port', label: _('Destination port'), kind: 'ports', help: _('e.g. <code>443</code> or <code>80,443,1000:2000</code>') },
	{ type: 'source', label: _('Source'), kind: 'text', help: _('Space separated: IP, CIDR or <code>geoip:private</code>.') },
	{ type: 'sourcePort', label: _('Source port'), kind: 'ports', help: _('e.g. <code>1000:2000,5000</code>') },
	{ type: 'protocol', label: _('Protocol (sniffed)'), kind: 'checks', values: [ [ 'http', 'HTTP' ], [ 'tls', 'TLS' ], [ 'quic', 'QUIC' ], [ 'bittorrent', 'BitTorrent' ] ] },
	{ type: 'inbound', label: _('Inbound'), kind: 'checks', values: [ [ 'tproxy', _('Transparent proxy') ], [ 'socks', _('SOCKS (node SOCKS port)') ] ] }
];

function condType(t) {
	return COND_TYPES.filter(function(c) { return c.type == t; })[0];
}

function resourceName(id) {
	const r = RESOURCES.filter(function(x) { return x.id == id; })[0];
	return r ? r.name : id + ' (' + _('missing') + ')';
}

function words(v) {
	return L.toArray(v).join(' ').split(/[\s,]+/).filter(function(x) { return x; });
}

/* UCI -> normalized condition object (only real conditions). */
function readConditions(sid) {
	const g = function(k) { return uci.get(CONFIG, sid, k); };
	const c = {};
	const res = L.toArray(g('domain_resource')).join(' ').split(/\s+/).filter(function(x) { return x; });
	if (res.length) c.domain_resource = res;
	if ((g('domain_list') || '').trim()) c.domain_list = g('domain_list');
	if ((g('ip_list') || '').trim()) c.ip_list = g('ip_list');
	if (g('network') == 'tcp' || g('network') == 'udp') c.network = g('network');
	if (g('port')) c.port = g('port');
	if (words(g('source')).length) c.source = words(g('source')).join(' ');
	if (g('sourcePort')) c.sourcePort = g('sourcePort');
	if (words(g('protocol')).length) c.protocol = words(g('protocol')).join(' ');
	if (words(g('inbound')).length) c.inbound = words(g('inbound')).join(' ');
	return c;
}

/* ---------- checks (rulecheck.js) ---------- */

function targetKind(t) {
	if (t == '_direct') return 'direct';
	if (t == '_blackhole') return 'block';
	if (t == '_default') return 'default';
	if (ev.isServer(t)) return 'server';
	if (ev.isGroup(t))
		return L.toArray(uci.get(CONFIG, t, 'urltest_node')).some(function(id) { return ev.isServer(id); }) ? 'group' : 'empty_group';
	return null;
}

/* Findings of all rules as they are now in uci (saved or staged). */
function findings() {
	return rc.analyze({
		rules: ev.rules().map(function(r) {
			return { id: r['.name'], name: r.remarks || r['.name'], target: uci.get(CONFIG, ROUTER, r['.name']) || '', cond: readConditions(r['.name']),
				opaque: uci.get(CONFIG, r['.name'], 'invert') == '1' };
		}),
		defaultTarget: uci.get(CONFIG, ROUTER, 'default_node') || '_direct',
		targetKind: targetKind,
		resourceOk: function(id) { return RESOURCES.some(function(x) { return x.id == id && x.exists; }); }
	});
}

function findingText(f) {
	switch (f.code) {
	case 'default_missing':
		return _('Default points to a node that does not exist any more. Choose the Default target on Main.');
	case 'default_empty_group':
		return _('Default is a URL Test group without servers. Add servers to the group or choose another Default on Main.');
	case 'resource_missing':
		return _('The domain resource "%s" is not installed: Easy VLESS does not start with this rule. Remove the resource from the rule or reinstall easy-vless.').format(f.resource);
	case 'protocol_network':
		return _('Never applies: the protocol %s is not carried over %s (TLS and HTTP are TCP, QUIC is UDP).').format(f.protocol, f.network);
	case 'no_target':
		return _('Off: the rule has no target, traffic it would match goes on to the rules below.');
	case 'target_missing':
		return _('The target points to a node that does not exist any more. Choose a target for this rule.');
	case 'target_empty_group':
		return _('The target is a URL Test group without servers. Add servers to the group or choose another target.');
	case 'target_default_missing':
		return _('The target is "Default target", and Default points to a node that does not exist.');
	case 'after_match_all':
		return f.sameTarget
			? _('Has no effect: rule "%s" above has no conditions and already sends everything to the same target.').format(f.otherName)
			: _('Never applies: rule "%s" above has no conditions and matches all traffic first. Move this rule above it.').format(f.otherName);
	case 'conflict':
		return _('Never applies: rule "%s" above has the same conditions and another target; the upper rule wins.').format(f.otherName);
	case 'duplicate':
		return _('Has no effect: rule "%s" above has the same conditions and the same target.').format(f.otherName);
	case 'shadowed':
		return _('Never applies: rule "%s" above already matches everything this rule matches, with another target. Move this rule above it.').format(f.otherName);
	case 'redundant':
		return _('Has no effect: rule "%s" above already matches everything this rule matches, with the same target.').format(f.otherName);
	case 'overlap':
		return _('Partly overridden: %s is also matched by rule "%s" above, which has another target and wins.').format(
			f.entries.join(', ') + (f.more ? ' ' + _('(and %d more)').format(f.more) : ''), f.otherName);
	case 'match_all':
		return f.last
			? _('No conditions: matches all traffic that reached it (it acts like Default).')
			: _('No conditions: matches all traffic that reached it - the rules below never apply.');
	}
	return f.code;
}

const LEVEL = { error: [ '❌', 'bad' ], warn: [ '⚠️', 'warn' ], info: [ 'ℹ️', 'info' ] };

/* Target as a coloured badge: where the traffic of a rule really goes. */
function targetBadge(t) {
	if (!t)
		return E('em', { 'style': 'opacity:.7' }, _('Not used'));
	const kind = targetKind(t);
	if (kind == null)
		return ev.badge(_('missing node'), 'bad');
	if (kind == 'default') {
		const def = uci.get(CONFIG, ROUTER, 'default_node') || '_direct';
		return E('span', {}, [ ev.badge(_('Default target'), 'idle'), ' ', E('small', { 'style': 'opacity:.75' }, '→ ' + ev.label(def)) ]);
	}
	return ev.badge(ev.label(t), kind == 'direct' ? 'info' : (kind == 'block' || kind == 'empty_group') ? 'bad' : 'ok');
}

function summary(sid) {
	const c = readConditions(sid);
	const parts = [];
	if (c.domain_resource) parts.push(_('Resource: %s').format(c.domain_resource.map(resourceName).join(', ')));
	if (c.domain_list) parts.push(_('%d domains').format(ev.lines(c.domain_list).length));
	if (c.ip_list) parts.push(_('%d IPs').format(ev.lines(c.ip_list).length));
	if (c.network) parts.push(c.network.toUpperCase());
	if (c.port) parts.push(_('port %s').format(c.port));
	if (c.source) parts.push(_('source %s').format(c.source));
	if (c.sourcePort) parts.push(_('source port %s').format(c.sourcePort));
	if (c.protocol) parts.push(_('protocol %s').format(c.protocol));
	if (c.inbound) parts.push(_('inbound %s').format(c.inbound));
	return parts.length ? parts.join(' · ') : _('no conditions (matches all)');
}

/*
 * Structured condition editor: a list of "type + value" rows with
 * "+ Add condition". Each type appears at most once; its value is written to
 * the matching UCI option (see readConditions / write).
 */
const ConditionsValue = form.Value.extend({
	__name__: 'CBI.EasyVlessConditions',

	load: function(section_id) {
		return readConditions(section_id);
	},

	rowsOf: function(obj) {
		return COND_TYPES.filter(function(c) { return obj && obj[c.type] != null; })
			.map(function(c) { return { type: c.type, value: obj[c.type] }; });
	},

	renderWidget: function(section_id, option_index, cfgvalue) {
		this.state = this.state || {};
		this.state[section_id] = this.rowsOf(cfgvalue);
		const box = E('div', { 'id': this.cbid(section_id) });
		this.boxes = this.boxes || {};
		this.boxes[section_id] = box;
		this.redraw(section_id, box);
		return box;
	},

	redraw: function(section_id, box) {
		const rows = this.state[section_id];
		const self = this;
		const redraw = function() { self.redraw(section_id, box); };

		const items = rows.map(function(row, i) {
			const def = condType(row.type);
			let widget;
			switch (def.kind) {
			case 'resources': {
				/* one dropdown per selected resource; "+" adds another one */
				const ids = L.toArray(row.value);
				if (!ids.length && RESOURCES.length) ids.push(RESOURCES[0].id);
				row.value = ids;
				const opts = function(sel) {
					return RESOURCES.map(function(r) {
						return E('option', { 'value': r.id, 'selected': (r.id == sel) ? '' : null },
							r.exists ? _('%s (entries: %d)').format(r.name, r.entries) : _('%s (file missing)').format(r.name));
					});
				};
				widget = E('div', {}, ids.map(function(id, k) {
					const sel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto;min-width:14em' }, opts(id));
					sel.addEventListener('change', function() { row.value[k] = sel.value; });
					return E('div', { 'style': 'margin:.15em 0' }, [ sel,
						ids.length > 1 ? E('button', { 'class': 'btn cbi-button', 'style': 'padding:0 .5em;margin-left:.3em', 'title': _('Remove this resource'),
							'click': function(ev_) { ev_.preventDefault(); row.value.splice(k, 1); redraw(); } }, '−') : '' ]);
				}).concat(RESOURCES.length > ids.length ? [ E('button', { 'class': 'btn cbi-button', 'style': 'padding:0 .5em',
					'title': _('Add another resource (any of them may match)'),
					'click': function(ev_) {
						ev_.preventDefault();
						const free = RESOURCES.filter(function(r) { return row.value.indexOf(r.id) < 0; })[0];
						if (free) row.value.push(free.id);
						redraw();
					} }, _('+ resource')) ] : []));
				if (!RESOURCES.length)
					widget = E('em', {}, _('No prepared resources installed.'));
				break;
			}
			case 'textarea':
				widget = E('textarea', { 'class': 'cbi-input-textarea', 'style': 'width:100%', 'rows': 6 }, row.value || '');
				widget.addEventListener('input', function() { row.value = widget.value; });
				break;
			case 'select':
				widget = E('select', { 'class': 'cbi-input-select' }, def.values.map(function(v) {
					return E('option', { 'value': v[0], 'selected': (row.value == v[0]) ? '' : null }, v[1]);
				}));
				if (row.value == null) row.value = def.values[0][0];
				widget.addEventListener('change', function() { row.value = widget.value; });
				break;
			case 'checks':
				widget = E('div', {}, def.values.map(function(v) {
					const cb = E('input', { 'type': 'checkbox', 'value': v[0] });
					cb.checked = words(row.value).indexOf(v[0]) > -1;
					cb.addEventListener('change', function() {
						const cur = words(row.value).filter(function(x) { return x != v[0]; });
						if (cb.checked) cur.push(v[0]);
						row.value = cur.join(' ');
					});
					return E('label', { 'style': 'margin-right:1em' }, [ cb, ' ', v[1] ]);
				}));
				break;
			default:
				widget = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': row.value || '', 'style': 'width:100%' });
				widget.addEventListener('input', function() { row.value = widget.value; });
			}
			return E('div', { 'style': 'display:grid;grid-template-columns:11em 1fr auto;gap:.2em .6em;align-items:start;padding:.35em 0;border-bottom:1px solid rgba(128,128,128,.25)' }, [
				E('strong', { 'style': 'padding-top:.35em' }, def.label),
				E('div', {}, [ widget,
					def.help ? (function() { const d = E('div', { 'class': 'cbi-value-description', 'style': 'margin-top:.2em' }); d.innerHTML = def.help; return d; })() : '' ]),
				E('button', { 'class': 'btn cbi-button cbi-button-remove', 'style': 'padding:0 .55em',
					'title': _('Remove condition'),
					'click': function(ev_) { ev_.preventDefault(); rows.splice(i, 1); redraw(); } }, '×')
			]);
		});

		const free = COND_TYPES.filter(function(c) { return !rows.some(function(r) { return r.type == c.type; }); });
		const sel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto' }, free.map(function(c) {
			return E('option', { 'value': c.type }, c.label);
		}));
		const add = free.length ? E('div', { 'style': 'margin-top:.5em' }, [
			sel, ' ',
			E('button', { 'class': 'btn cbi-button cbi-button-add', 'click': function(ev_) {
				ev_.preventDefault();
				const def = condType(sel.value);
				rows.push({ type: def.type, value: def.kind == 'resources' ? (RESOURCES.length ? [ RESOURCES[0].id ] : []) : (def.kind == 'select' ? def.values[0][0] : '') });
				redraw();
			} }, _('+ Add condition'))
		]) : '';

		dom.content(box, (items.length ? items : [ E('p', {}, E('em', {}, _('No conditions: the rule matches all traffic.'))) ]).concat([
			E('div', { 'class': 'ev-cond-error', 'style': 'color:#c62828;font-weight:bold' }),
			add,
			E('div', { 'class': 'cbi-value-description', 'style': 'margin-top:.5em' },
				_('How conditions combine (sing-box): all condition types must match; Domain Resource, Domain and IP are alternatives - any one of them may match.'))
		]));
	},

	formvalue: function(section_id) {
		const obj = {};
		L.toArray(this.state && this.state[section_id]).forEach(function(r) {
			let v = r.value;
			if (r.type == 'domain_resource') {
				v = L.toArray(v);
				if (v.length) obj[r.type] = v;
				return;
			}
			if (r.type == 'source' || r.type == 'protocol' || r.type == 'inbound')
				v = words(v).join(' ');
			if (v != null && String(v).trim() !== '')
				obj[r.type] = (r.type == 'port' || r.type == 'sourcePort') ? String(v).replace(/\s+/g, '') : v;
		});
		return obj;
	},

	validateState: function(section_id) {
		const v = this.formvalue(section_id);
		if (v.port && !ev.validPorts(v.port))
			return _('Destination port: expecting ports (1-65535) or ranges from:to separated by commas');
		if (v.sourcePort && !ev.validPorts(v.sourcePort))
			return _('Source port: expecting ports (1-65535) or ranges from:to separated by commas');
		const badSrc = words(v.source).filter(function(w) { return w != 'geoip:private' && !/^[0-9a-fA-F:.]+(\/\d{1,3})?$/.test(w); });
		if (badSrc.length)
			return _('Source: "%s" is not an IP, CIDR or geoip:private').format(badSrc[0]);
		const badDom = ev.lines(v.domain_list).filter(function(l) {
			const m = l.match(/^([a-z-]+):/);
			return m && [ 'domain', 'full', 'regexp', 'geosite', 'rule-set', 'rs' ].indexOf(m[1]) < 0;
		});
		if (badDom.length)
			return _('Domain: unknown prefix in "%s"').format(badDom[0]);
		const rows = L.toArray(this.state && this.state[section_id]);
		if (rows.some(function(r) { return r.type == 'domain_resource' && !L.toArray(r.value).length; }))
			return _('Domain Resource: select at least one resource or remove the condition');
		const bad = rc.contradiction(v);
		if (bad)
			return _('Network %s and protocol %s exclude each other (TLS and HTTP are TCP, QUIC is UDP): the rule would never apply').format(bad.network, bad.protocol);
		return null;
	},

	/* Invalid values are shown inside the editor (LuCI's modal save only
	 * highlights its own widgets). */
	isValid: function(section_id) {
		const err = this.validateState(section_id);
		const box = this.boxes && this.boxes[section_id];
		const el = box ? box.querySelector('.ev-cond-error') : null;
		if (el)
			el.textContent = err || '';
		return err == null;
	},

	getValidationError: function(section_id) {
		return this.validateState(section_id) || '';
	},

	write: function(section_id, obj) {
		[ 'domain_resource', 'domain_list', 'ip_list', 'port', 'source', 'sourcePort', 'protocol', 'inbound' ].forEach(function(k) {
			if (obj[k] != null)
				uci.set(CONFIG, section_id, k, obj[k]);
			else
				uci.unset(CONFIG, section_id, k);
		});
		/* no Network condition = both (explicit, as PassWall2 stores it) */
		uci.set(CONFIG, section_id, 'network', obj.network || 'tcp,udp');
	},

	remove: function(section_id) {
		this.write(section_id, {});
	}
});

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(CONFIG),
			ev.callStatus(),
			ev.callResources()
		]);
	},

	handleMove: function(sid, up) {
		return ev.exclusive(_('Move'), L.bind(function() {
			if (!ev.moveSection(sid, up))
				return;
			return ev.saveAndCommit(this.map);
		}, this));
	},

	/* Highest priority: the rule becomes the first one. */
	handleTop: function(sid) {
		return ev.exclusive(_('Move'), L.bind(function() {
			const first = ev.rules()[0];
			if (!first || first['.name'] == sid)
				return;
			uci.move(CONFIG, sid, first['.name'], false);
			return ev.saveAndCommit(this.map);
		}, this));
	},

	/* Errors and warnings of all rules above the table. */
	renderFindings: function() {
		const list = findings().filter(function(f) { return f.level != 'info'; });
		if (!list.length)
			return E('div', { 'id': 'ev-rule-findings' });
		return E('div', { 'id': 'ev-rule-findings', 'class': 'alert-message warning' }, [
			E('p', {}, E('strong', {}, _('%d rule problem(s) found:').format(list.length))),
			E('ul', { 'style': 'margin:.2em 0 0 1.2em' }, list.map(function(f) {
				return E('li', {}, [ LEVEL[f.level][0], ' ',
					f.rule ? E('strong', {}, '%d. %s: '.format(f.order, f.name)) : E('strong', {}, _('Default') + ': '), findingText(f) ]);
			}))
		]);
	},

	refreshFindings: function() {
		const el = document.getElementById('ev-rule-findings');
		if (el)
			el.parentNode.replaceChild(this.renderFindings(), el);
	},

	/* Prepared rule from the resource manifest (explicit user action; the
	 * First Run Wizard uses the same templates through ev.applyTemplate).
	 * Staged; Save commits it. */
	handleTemplate: function(select) {
		const t = TEMPLATES.filter(function(x) { return x.id == select.value; })[0];
		if (!t)
			return Promise.resolve();
		const exists = ev.rules().some(function(r) { return (r.remarks || '') == t.remarks; });
		if (exists) {
			ev.notify(_('A rule named "%s" already exists.').format(t.remarks), 'warning');
			return Promise.resolve();
		}
		/* "@active" = the selected VLESS node (ev.selectedNode) */
		const target = ev.applyTemplate(t, null, ev.selectedNode()).target;
		return ev.exclusive(_('Add prepared rule'), L.bind(function() {
			return ev.saveAndCommit(this.map).then(function() {
				ev.notify(target
					? _('Rule "%s" added with target %s. Change it on Main if needed.').format(t.remarks, ev.label(target))
					: _('Rule "%s" added. Choose its target on Main.').format(t.remarks));
			});
		}, this));
	},

	renderResources: function() {
		if (!RESOURCES.length)
			return E('p', {}, E('em', {}, _('No prepared resources installed.')));
		return E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [ _('Resource'), _('Type'), _('Entries'), _('Status'), _('File') ].map(function(t) { return E('th', { 'class': 'th' }, t); }))
		].concat(RESOURCES.map(function(r) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, E('strong', {}, r.name)),
				E('td', { 'class': 'td' }, r.type == 'domain' ? _('Domain resource') : r.type),
				E('td', { 'class': 'td' }, r.exists ? String(r.entries) : '-'),
				E('td', { 'class': 'td' }, r.exists ? ev.badge(_('Installed'), 'ok') : ev.badge(_('Missing'), 'bad')),
				E('td', { 'class': 'td' }, E('small', {}, r.path || ''))
			]);
		})));
	},

	render: function(data) {
		const status = data[1] || {};
		const res = data[2] || {};
		RESOURCES = res.ok ? L.toArray(res.resources) : [];
		TEMPLATES = res.ok ? L.toArray(res.rule_templates) : [];
		let m, s, o;
		const view_ = this;

		ev.ensureRouter();

		m = this.map = new form.Map(CONFIG);

		s = m.section(form.GridSection, 'shunt_rules', _('Rules'),
			_('Checked from top to bottom: the first matching rule wins (higher = higher priority). Unmatched traffic goes to Default (Main). A rule whose target is "Not used" is inactive.'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = false;
		s.nodescriptions = true;
		s.addbtntitle = _('Add rule');
		ev.compactWhenEmpty(s, _('No rules yet. The quickest start: choose a prepared rule next to Add rule and press Add prepared rule.'));
		ev.commitOnModalSave(s, _('Rule'));
		s.modaltitle = function(section_id) {
			return ev.esc(_('Rule') + ' » ' + (uci.get(CONFIG, section_id, 'remarks') || _('New rule')));
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
			const name = uci.get(CONFIG, section_id, 'remarks') || section_id;
			return ev.confirm(_('Delete rule'), _('Delete rule "%s"? This cannot be undone.').format(name)).then(L.bind(function(ok) {
				if (!ok) return;
				return ev.exclusive(_('Delete'), L.bind(function() {
				uci.unset(CONFIG, ROUTER, section_id);
				this.map.data.remove(CONFIG, section_id);
				return ev.saveAndCommit(this.map).then(function() { ev.notify(_('Rule deleted.')); });
				}, this));
			}, this));
		};
		s.renderRowActions = function(section_id) {
			const td = form.GridSection.prototype.renderRowActions.apply(this, [ section_id ]);
			const box = td.lastElementChild;
			box.insertBefore(ev.smallButton('↓', _('Down', 'move row'), '', ui.createHandlerFn(view_, 'handleMove', section_id, false)), box.firstChild);
			box.insertBefore(ev.smallButton('↑', _('Up', 'move row'), '', ui.createHandlerFn(view_, 'handleMove', section_id, true)), box.firstChild);
			box.insertBefore(ev.smallButton('⤒', _('Make this the first rule (highest priority)'), '', ui.createHandlerFn(view_, 'handleTop', section_id)), box.firstChild);
			return td;
		};
		s.renderSectionAdd = function(extra_class) {
			const el = form.GridSection.prototype.renderSectionAdd.apply(this, [ extra_class ]);
			if (TEMPLATES.length) {
				const sel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto;margin-left:1em' },
					TEMPLATES.map(function(t) { return E('option', { 'value': t.id }, t.remarks); }));
				el.appendChild(sel);
				el.appendChild(E('button', {
					'class': 'btn cbi-button cbi-button-add', 'style': 'margin-left:.3em',
					'title': _('Add a prepared rule (conditions from the resource manifest)'),
					'click': ui.createHandlerFn(view_, 'handleTemplate', sel)
				}, _('Add prepared rule')));
			}
			return el;
		};

		/* Editor: Name, Conditions, Action (target) - one flat form. */
		o = s.option(form.Value, 'remarks', _('Name'));
		o.rmempty = false;

		o = s.option(form.DummyValue, '_order', _('Order'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			return String(ev.rules().findIndex(function(r) { return r['.name'] == section_id; }) + 1);
		};

		o = s.option(form.DummyValue, '_conditions', _('Conditions'));
		o.modalonly = false;
		o.textvalue = function(section_id) { return E('span', {}, summary(section_id)); };

		o = s.option(ConditionsValue, '_cond', _('Conditions'));
		o.modalonly = true;

		o = s.option(form.ListValue, '_target', _('Target', 'routing target'),
			_('Where matching traffic goes (also selectable on Main). Used while the Main Router is the main node.'));
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
			return targetBadge(uci.get(CONFIG, ROUTER, section_id));
		};

		/* Checks of this rule against the rules above it and its target. */
		o = s.option(form.DummyValue, '_checks', _('Checks', 'rule checks'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const list = findings().filter(function(f) { return f.rule == section_id; });
			if (!list.length)
				return E('span', { 'title': _('No problem found') }, '✅');
			return E('div', { 'class': 'ev-rule-checks' }, list.map(function(f) {
				return E('div', { 'data-level': f.level, 'data-code': f.code, 'style': 'font-size:90%;' + (f.level == 'info' ? 'opacity:.8' : '') },
					[ LEVEL[f.level][0], ' ', findingText(f) ]);
			}));
		};


		return m.render().then(L.bind(function(mapEl) {
			poll.add(L.bind(ev.refreshStatus, ev), 5);
			/* every save re-renders the table: refresh the summary with it */
			const renderContents = m.renderContents;
			m.renderContents = function() {
				return renderContents.apply(this, arguments).then(function(el) {
					view_.refreshFindings();
					return el;
				});
			};
			return E('div', { 'class': 'ev-page' }, [
				ev.pageStyle(),
				E('h2', {}, _('Rule Manage')),
				E('div', { 'class': 'cbi-map-descr' }, _('A rule says which traffic it matches (conditions: domains, IPs, ports...). Where the matching traffic goes (Direct, a server, Block) is its target, set here or on Main. Rules work while Node on Main is "Main Router".')),
				ev.renderHeader(m, status, null, true),
				ev.shuntEnabled() ? '' : E('div', { 'class': 'alert-message' },
					E('p', {}, _('Rules are not used right now: Node on Main is not the Main Router. Select "Main Router (shunt)" as Node on Main to route by rules.'))),
				this.renderFindings(),
				mapEl,
				E('p', { 'class': 'cbi-value-description' }, [
					_('To see which rule a domain or address really gets, use Route Explain:') + ' ',
					E('a', { 'href': L.url('admin/services/easy_vless/diagnostics') }, _('Diagnostics')) ]),
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('Resources')),
					E('div', { 'class': 'cbi-section-descr' }, res.ok
						? _('Prepared domain lists installed with Easy VLESS. Use them in a rule with the condition "Domain Resource".')
						: _('Resources unavailable: %s').format(res.error || '')),
					this.renderResources()
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
