/*
 * Easy VLESS - Rule Manage checks (0.9.0), unit test of
 * luci/htdocs/luci-static/resources/easy_vless/rulecheck.js without a browser.
 *
 *   node tests/rule-check-test.js      (static checks, CI "checks" job)
 *
 * Covered: rules that can never apply (covered by an earlier rule, after a
 * rule that matches everything, contradicting conditions), conflicting and
 * duplicate rules, entries caught by an earlier rule, missing targets and
 * resources - and that normal configurations (the prepared RUSSIA / PROXY /
 * QUIC / UDP rules) produce no warning.
 */
'use strict';
const fs = require('fs');
const path = require('path');

let pass = 0, fail = 0;
function check(msg, cond) {
	if (cond) { pass++; console.log('PASS: ' + msg); }
	else { fail++; console.log('FAIL: ' + msg); }
}
const src = fs.readFileSync(path.join(__dirname, '..', 'luci', 'htdocs', 'luci-static', 'resources', 'easy_vless', 'rulecheck.js'), 'utf8');
const rc = new Function('baseclass', src)({ extend: function(o) { return o; } });

const NODES = { srv: 'server', srv2: 'server', grp: 'group', egrp: 'empty_group' };
const kind = function(t) {
	if (t == '_direct') return 'direct';
	if (t == '_blackhole') return 'block';
	if (t == '_default') return 'default';
	return NODES[t] || null;
};
const analyze = function(rules, def) {
	return rc.analyze({ rules: rules, defaultTarget: def || 'srv', targetKind: kind, resourceOk: function(id) { return id == 'russia' || id == 'proxy'; } });
};
const rule = function(id, target, cond) { return { id: id, name: id, target: target, cond: cond || {} }; };
const of = function(findings, id) { return findings.filter(function(f) { return f.rule == id; }).map(function(f) { return f.level + ':' + f.code; }).join(' '); };
const warnings = function(findings) { return findings.filter(function(f) { return f.level != 'info'; }); };

/* ---- the prepared rules: nothing to report ---- */
const prepared = [
	rule('RUSSIA', '_direct', { domain_resource: [ 'russia' ], network: 'tcp,udp' }),
	rule('PROXY', 'srv', { domain_resource: [ 'proxy' ], network: 'tcp,udp' }),
	rule('QUIC', 'srv', { network: 'udp', port: '443' }),
	rule('UDP', 'srv', { network: 'udp' })
];
let f = analyze(prepared);
check('prepared rules: no finding at all (' + f.length + ')', f.length == 0);
f = analyze(prepared, '_direct');
check('prepared rules with Default Direct: no finding', f.length == 0);

/* ---- wrong order: a general rule above a specific one ---- */
f = analyze([ prepared[0], prepared[1], rule('UDP', '_direct', { network: 'udp' }), rule('QUIC', 'srv', { network: 'udp', port: '443' }) ]);
check('UDP above QUIC with another target: QUIC is shadowed and never applies (' + of(f, 'QUIC') + ')', of(f, 'QUIC') == 'warn:shadowed' && f[0].other == 'UDP' && f[0].order == 4);
f = analyze([ rule('UDP', 'srv', { network: 'udp' }), rule('QUIC', 'srv', { network: 'udp', port: '443' }) ]);
check('the same with the same target: only redundant (info)', of(f, 'QUIC') == 'info:redundant');

/* ---- conflict and duplicate ---- */
f = analyze([ rule('A', '_direct', { domain_list: 'domain:example.org' }), rule('B', 'srv', { domain_list: 'domain:example.org' }) ]);
check('same conditions, other target: conflict', of(f, 'B') == 'warn:conflict' && f[0].otherName == 'A');
f = analyze([ rule('A', 'srv', { domain_list: 'domain:example.org' }), rule('B', 'srv', { domain_list: 'domain:example.org' }) ]);
check('same conditions, same target: duplicate (info)', of(f, 'B') == 'info:duplicate');
f = analyze([ rule('A', 'srv', { domain_list: 'domain:example.org' }), rule('B', '_default', { domain_list: 'domain:example.org' }) ], 'srv');
check('"Default target" counts as the Default it resolves to', of(f, 'B') == 'info:duplicate');

/* ---- covered by an earlier rule ---- */
f = analyze([ rule('A', '_direct', { domain_list: 'domain:google.com' }), rule('B', 'srv', { domain_list: 'full:mail.google.com\ndomain:maps.google.com' }) ]);
check('subdomains of a domain an earlier rule has: shadowed', of(f, 'B') == 'warn:shadowed');
f = analyze([ rule('A', '_direct', { domain_list: 'google' }), rule('B', 'srv', { domain_list: 'domain:google.com' }) ]);
check('a keyword above covers a domain that contains it', of(f, 'B') == 'warn:shadowed');
f = analyze([ rule('A', '_direct', { domain_list: 'domain:mail.google.com' }), rule('B', 'srv', { domain_list: 'domain:google.com' }) ]);
check('the specific rule above the general one: fine', of(f, 'B') == '');
f = analyze([ rule('A', '_direct', { domain_list: 'domain:google.com' }), rule('B', 'srv', { domain_list: 'domain:notgoogle.com' }) ]);
check('a longer name is not a subdomain', of(f, 'B') == '');
f = analyze([ rule('A', '_direct', { ip_list: '10.0.0.0/8' }), rule('B', 'srv', { ip_list: '10.1.2.0/24\n10.9.9.9' }) ]);
check('IP ranges inside an earlier range: shadowed', of(f, 'B') == 'warn:shadowed');
f = analyze([ rule('A', '_direct', { ip_list: '10.1.2.0/24' }), rule('B', 'srv', { ip_list: '10.0.0.0/8' }) ]);
check('a wider range below a narrower one: fine', of(f, 'B') == '');
f = analyze([ rule('A', '_direct', { port: '1:1024' }), rule('B', 'srv', { port: '80,443', network: 'tcp' }) ]);
check('ports inside an earlier port range: shadowed', of(f, 'B') == 'warn:shadowed');
f = analyze([ rule('A', '_direct', { port: '80' }), rule('B', 'srv', { port: '80,443' }) ]);
check('only part of the ports covered: no claim', of(f, 'B') == '');
f = analyze([ rule('A', '_direct', { network: 'tcp' }), rule('B', 'srv', { domain_list: 'domain:example.org' }) ]);
check('an earlier TCP-only rule does not cover a rule for both networks', of(f, 'B') == '');
f = analyze([ rule('A', '_direct', { domain_resource: [ 'proxy' ] }), rule('B', 'srv', { domain_list: 'domain:youtube.com' }) ]);
check('what is inside a resource is not known: no claim', of(f, 'B') == '');
f = analyze([ rule('A', '_direct', { domain_resource: [ 'proxy', 'russia' ] }), rule('B', 'srv', { domain_resource: [ 'proxy' ] }) ]);
check('the same resource in an earlier rule: shadowed', of(f, 'B') == 'warn:shadowed');
f = analyze([ rule('A', '_direct', { source: '192.168.1.0/24' }), rule('B', 'srv', { source: '192.168.1.50', domain_list: 'domain:example.org' }) ]);
check('source inside an earlier source range: shadowed', of(f, 'B') == 'warn:shadowed');
f = analyze([ rule('A', '_direct', { protocol: 'tls http' }), rule('B', 'srv', { protocol: 'tls', port: '443' }) ]);
check('protocol set inside an earlier one: shadowed', of(f, 'B') == 'warn:shadowed');

/* ---- a rule that matches everything ---- */
f = analyze([ rule('ALL', '_direct', {}), rule('B', 'srv', { domain_list: 'domain:example.org' }), rule('C', '_direct', { network: 'udp' }) ]);
check('a rule without conditions is pointed out', of(f, 'ALL') == 'info:match_all');
check('every rule below it never applies (other target: warning, same target: info)', of(f, 'B') == 'warn:after_match_all' && of(f, 'C') == 'info:after_match_all');
f = analyze([ rule('B', 'srv', { domain_list: 'domain:example.org' }), rule('ALL', '_direct', {}) ]);
check('a catch-all as the last rule is fine', of(f, 'ALL') == 'info:match_all' && f.filter(function(x) { return x.code == 'match_all'; })[0].last === true && of(f, 'B') == '');

/* ---- entries caught by an earlier rule ---- */
f = analyze([ rule('A', '_direct', { domain_list: 'domain:youtube.com\ndomain:vk.com' }), rule('B', 'srv', { domain_resource: [ 'proxy' ], domain_list: 'domain:youtube.com\ndomain:x.com' }) ]);
check('one entry of the rule is also in an earlier rule with another target: overlap', of(f, 'B') == 'warn:overlap' && f[0].entries.join() == 'youtube.com' && f[0].otherName == 'A');
f = analyze([ rule('A', 'srv', { domain_list: 'domain:youtube.com' }), rule('B', 'srv', { domain_list: 'domain:youtube.com\ndomain:x.com' }) ]);
check('the same entry with the same target: nothing to report', of(f, 'B') == '');
f = analyze([ rule('A', '_direct', { domain_list: 'domain:youtube.com', port: '443' }), rule('B', 'srv', { domain_list: 'domain:youtube.com\ndomain:x.com' }) ]);
check('an earlier rule limited to a port does not catch the entry in general', of(f, 'B') == '');

/* ---- conditions that contradict each other ---- */
check('QUIC over TCP can never match', rc.contradiction({ network: 'tcp', protocol: 'quic' }).code == 'protocol_network');
check('TLS / HTTP over UDP can never match', rc.contradiction({ network: 'udp', protocol: 'tls http' }) != null);
check('QUIC over UDP, TLS over TCP, BitTorrent over either: fine', rc.contradiction({ network: 'udp', protocol: 'quic' }) == null && rc.contradiction({ network: 'tcp', protocol: 'tls' }) == null
	&& rc.contradiction({ network: 'udp', protocol: 'bittorrent' }) == null && rc.contradiction({ network: 'tcp', protocol: 'quic tls' }) == null);
check('both networks: no contradiction', rc.contradiction({ network: 'tcp,udp', protocol: 'quic' }) == null && rc.contradiction({ protocol: 'quic' }) == null);
f = analyze([ rule('Q', 'srv', { network: 'tcp', protocol: 'quic' }) ]);
check('reported in the rule list', of(f, 'Q') == 'warn:protocol_network' && f[0].protocol == 'QUIC' && f[0].network == 'TCP');

/* ---- targets and resources ---- */
f = analyze([ rule('A', 'gone', { network: 'udp' }) ]);
check('target points to a node that does not exist: error', of(f, 'A') == 'error:target_missing' && f[0].target == 'gone');
f = analyze([ rule('A', 'egrp', { network: 'udp' }) ]);
check('target is a URL Test group without servers: error', of(f, 'A') == 'error:target_empty_group');
f = analyze([ rule('A', '', { network: 'udp' }) ]);
check('no target: the rule is off (info), and it shadows nothing', of(f, 'A') == 'info:no_target');
f = analyze([ rule('OFF', '', {}), rule('B', 'srv', { network: 'udp' }) ]);
check('a rule that is off does not shadow the rules below', of(f, 'B') == '');
f = analyze([ rule('A', '_blackhole', { network: 'udp' }), rule('B', 'grp', { network: 'tcp' }) ]);
check('Block and URL Test group targets are valid', warnings(f).length == 0);
f = analyze([ rule('A', 'srv', { domain_resource: [ 'nope' ] }) ]);
check('a resource that is not installed: error (the start would fail)', of(f, 'A') == 'error:resource_missing' && f[0].resource == 'nope');
f = analyze([ rule('A', '_default', { network: 'udp' }) ], 'gone');
check('Default points to a missing node: error for Default and for rules that follow it',
	f.some(function(x) { return x.rule == null && x.code == 'default_missing'; }) && of(f, 'A') == 'error:target_default_missing');
f = analyze([], 'egrp');
check('Default is an empty group', f[0].code == 'default_empty_group');

/* ---- helper ---- */
check('covers(): port lists and ranges', rc.covers({ port: '1000:2000' }, { port: '1500', network: 'tcp' }) && !rc.covers({ port: '1000:2000' }, { port: '999' }) && !rc.covers({ port: '80' }, {}));
check('ipCovers(): CIDR containment', rc.ipCovers('192.168.0.0/16', '192.168.5.0/24') && !rc.ipCovers('192.168.5.0/24', '192.168.0.0/16') && rc.ipCovers('geoip:ru', 'geoip:ru') && !rc.ipCovers('geoip:ru', '5.255.255.70'));

console.log('\n===== Rule Manage checks: ' + pass + ' passed, ' + fail + ' failed =====');
process.exit(fail ? 1 : 0);
