'use strict';
'require view';
'require form';
'require uci';
'require poll';
'require easy_vless.common as ev';

/*
 * Easy VLESS - Settings: DNS, Forwarding, Other (PassWall2 "Basic Settings
 * -> DNS" and "Other Settings" models, reduced to what the Easy VLESS
 * runtime really reads: app.sh, app_acl.lua, nftables.sh,
 * util_sing-box.lua). Changes apply on the next (re)start (Save & Apply).
 */

const CONFIG = ev.CONFIG;

function portsValidate(section_id, value) {
	if (ev.validPorts(value))
		return true;
	return _('Expecting ports (1-65535) or ranges from:to separated by commas');
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(CONFIG),
			ev.callStatus()
		]);
	},

	render: function(data) {
		const status = data[1] || {};
		let m, s, o;

		m = this.map = new form.Map(CONFIG);

		/* ===== DNS ===== */
		s = m.section(form.NamedSection, 'global', 'global', _('DNS'),
			_('sing-box DNS: direct DNS for direct traffic, remote DNS (through the proxy) for proxied domains. dnsmasq forwards to sing-box while Easy VLESS runs.'));
		s.addremove = false;

		o = s.option(form.ListValue, 'direct_dns_protocol', _('Direct DNS'));
		o.value('auto', _('Auto (ISP / dnsmasq upstream)'));
		o.value('udp', 'UDP');
		o.value('tcp', 'TCP');
		o.default = 'auto';

		o = s.option(form.Value, 'direct_dns', _('Direct DNS server'), _('IP or IP:port.'));
		o.depends('direct_dns_protocol', 'udp');
		o.depends('direct_dns_protocol', 'tcp');
		o.datatype = 'or(ipaddr,ipaddrport(1))';
		o.rmempty = false;

		o = s.option(form.ListValue, 'direct_dns_query_strategy', _('Direct Query Strategy'));
		o.value('UseIP');
		o.value('UseIPv4');
		o.value('UseIPv6');
		o.default = 'UseIP';

		o = s.option(form.ListValue, 'remote_dns_protocol', _('Remote DNS Protocol'));
		o.value('tcp', 'TCP');
		o.value('udp', 'UDP');
		o.value('tls', 'DoT (TLS)');
		o.value('doh', 'DoH (HTTPS)');
		o.default = 'tcp';

		o = s.option(form.Value, 'remote_dns', _('Remote DNS'), _('IP or IP:port.'));
		o.depends('remote_dns_protocol', 'tcp');
		o.depends('remote_dns_protocol', 'udp');
		o.depends('remote_dns_protocol', 'tls');
		[ '1.1.1.1', '1.0.0.1', '8.8.8.8', '8.8.4.4', '9.9.9.9' ].forEach(function(v) { o.value(v); });
		o.datatype = 'or(ipaddr,ipaddrport(1))';
		o.default = '1.1.1.1';

		o = s.option(form.Value, 'remote_dns_doh', _('Remote DNS DoH'),
			_('URL, optionally followed by a bootstrap IP: <code>https://dns.google/dns-query,8.8.8.8</code>.'));
		o.depends('remote_dns_protocol', 'doh');
		o.value('https://1.1.1.1/dns-query');
		o.value('https://8.8.4.4/dns-query');
		o.value('https://dns.google/dns-query,8.8.8.8');
		o.value('https://dns.quad9.net/dns-query,9.9.9.9');
		o.default = 'https://1.1.1.1/dns-query';
		o.validate = function(section_id, value) {
			return /^https:\/\/\S+$/.test(value || '') ? true : _('Expecting an https:// URL');
		};

		o = s.option(form.Value, 'remote_dns_client_ip', _('Remote DNS EDNS Client Subnet'),
			_('Public IP sent to the DNS server as client location (RFC 7871). Empty = off.'));
		o.datatype = 'ipaddr';

		o = s.option(form.ListValue, 'remote_dns_detour', _('Remote DNS Outbound'));
		o.value('remote', _('Remote (through the proxy)'));
		o.value('direct', _('Direct'));
		o.default = 'remote';

		o = s.option(form.Flag, 'remote_fakedns', _('FakeDNS'),
			_('Answer proxied domains with fake IPs (faster, the real resolution happens on the server).'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'remote_dns_query_strategy', _('Remote Query Strategy'));
		o.value('UseIP');
		o.value('UseIPv4');
		o.value('UseIPv6');
		o.default = 'UseIPv4';

		o = s.option(form.TextValue, 'dns_hosts', _('Domain Override'),
			_('One per line: <code>domain IP</code>, e.g. <code>dns.google 8.8.8.8</code>.'));
		o.rows = 4;

		o = s.option(form.Flag, 'dns_redirect', _('DNS Redirect'),
			_('Redirect DNS queries of proxied LAN devices to the router (dnsmasq), so their lookups follow the Easy VLESS DNS rules.'));
		o.default = '1';
		o.rmempty = false;

		/* ===== Forwarding ===== */
		s = m.section(form.NamedSection, 'global_forwarding', 'global_forwarding', _('Forwarding'),
			_('nftables (fw4) transparent proxy: table inet easy_vless, TPROXY + fwmark routing. Ports: single ports and ranges <code>from:to</code>, comma separated, e.g. <code>21,80,443,1000:2000</code>.'));
		s.addremove = false;

		o = s.option(form.Value, 'tcp_no_redir_ports', _('TCP No Redir Ports'),
			_('Never proxied (highest priority). Empty = none.'));
		o.validate = portsValidate;

		o = s.option(form.Value, 'udp_no_redir_ports', _('UDP No Redir Ports'),
			_('Never proxied (highest priority). Empty = none.'));
		o.validate = portsValidate;

		o = s.option(form.Value, 'tcp_redir_ports', _('TCP Redir Ports'));
		o.value('1:65535', _('All'));
		o.value('22,25,53,80,143,443,465,587,853,993,995,8080,8443', _('Common ports'));
		o.default = '1:65535';
		o.validate = portsValidate;

		o = s.option(form.Value, 'udp_redir_ports', _('UDP Redir Ports'));
		o.value('1:65535', _('All'));
		o.default = '1:65535';
		o.validate = portsValidate;

		o = s.option(form.ListValue, 'tcp_proxy_way', _('TCP Proxy Way'));
		o.value('tproxy', 'TPROXY');
		o.value('redirect', 'REDIRECT');
		o.default = 'tproxy';

		o = s.option(form.Flag, 'ipv6_tproxy', _('IPv6 TProxy'),
			_('Experimental. Make sure your server supports IPv6.'));
		o.rmempty = false;

		o = s.option(form.Flag, 'accept_icmp', _('Hijacking ICMP (PING)'));
		o.rmempty = false;

		/* ===== Other ===== */
		s = m.section(form.NamedSection, 'global', 'global', _('Advanced'));
		s.addremove = false;

		o = s.option(form.ListValue, 'routing_mode', _('Routing mode'),
			_('<b>singbox</b>: all redirected traffic enters sing-box, which applies the rules.'));
		o.value('singbox', 'singbox');
		o.default = 'singbox';

		o = s.option(form.ListValue, 'loglevel', _('Log level'));
		[ 'debug', 'info', 'warn', 'error' ].forEach(function(l) { o.value(l); });
		o.default = 'warn';

		o = s.option(form.Flag, 'log_node', _('sing-box log'),
			_('Write the sing-box log to /tmp/etc/easy_vless/.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'clash_api_port', _('Clash API port'),
			_('Local port (127.0.0.1) of the sing-box Clash API used for URL Test results; a free port is picked if it is busy.'));
		o.datatype = 'port';
		o.placeholder = '9095';

		o = s.option(form.Value, 'node_socks_port', _('Node SOCKS port'),
			_('Optional local SOCKS5 inbound of the main instance (rule inbound "SOCKS"). Empty = off.'));
		o.datatype = 'port';

		o = s.option(form.Flag, 'node_socks_bind_local', _('SOCKS bind local'),
			_('Listen on 127.0.0.1 only.'));
		o.default = '1';
		o.depends({ node_socks_port: /.+/ });

		s = m.section(form.NamedSection, 'global_delay', 'global_delay');
		s.addremove = false;

		o = s.option(form.Value, 'start_delay', _('Delay Start'), _('Seconds to wait after boot before starting.'));
		o.datatype = 'uinteger';
		o.placeholder = '1';

		return m.render().then(L.bind(function(mapEl) {
			poll.add(L.bind(ev.refreshStatus, ev), 5);
			return E('div', { 'class': 'ev-page' }, [
				ev.pageStyle(),
				E('h2', {}, _('Settings')),
				ev.renderHeader(m, status, null, true),
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
