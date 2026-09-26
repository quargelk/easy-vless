# Easy VLESS Current State

Canonical handoff. Read this first; work only in the area a task touches; do not re-investigate the resolved bugs below unless a new symptom points at them. Update this file after substantial changes.

Status legend: **LOCAL** = verified in the Claude sandbox harness (x86_64 container: real sing-box 1.12.22, real nftables/TPROXY, real rpcd/ubus/uci, LuCI JS in headless Chromium, stubs for fw4/dnsmasq/netifd). **TR3000** = verified on the real router. **UNVERIFIED** = neither.

## Version

- Packages: **0.5.0-r2** (release candidate; 0.5.0-r1 = GUI + prepared resources + bugfixes, r2 = RC fixes below). Previous: 0.4.0-r1 (committed `b1480ca` "feat: consolidate Easy VLESS MVP"), 0.3.0-r2.
- Repository: https://github.com/quargelk/easy-vless, branch `main`
- Upstream/reference: PassWall2 25.5.15-1, commit 394f3842969161ddd888187e72db4b493b3310b4

## Changes in 0.5.0

- Prepared resources: `proxy.txt` / `russia.txt` (byte copies of `reference/domains`, CRLF kept) + `manifest.json` in the core package; rules reference them by id (`shunt_rules.domain_resource`); api.lua merges the file into the rule's domain list at config generation (sing-box and xray generators); app.sh check refuses unknown/missing resources and scans them for geosite:/geoip:.
- Rule Manage: structured Conditions editor (type + value rows, "+ Add condition", Domain Resource first-class), rule list with Name / Order / Conditions / Target / ↑ ↓ Edit Delete, prepared rule templates (RUSSIA, PROXY, QUIC, UDP) from the manifest, Resources table (installed, entries).
- Service controls (Save & Start / Stop / Check config) only on Main; Node List and Settings show status only. Footer Save / Save & Apply / Reset stays on every page.
- Node List: actions Use / Test / URL Test / Copy / ↑ / ↓ / Edit / Delete; Status column = real usage (Active / Selected (stopped) / Active (group) / Used by / Inactive) + last Server Test and URL Test; compact empty URL Test / Subscription sections; "Update all subscriptions" inside the Subscriptions section; import result shows the parsed fields of every imported server.
- Per-node URL Test: rpcd `urltest_node` optional `url` (LuCI passes https://x.com); Server Test unchanged (default https://www.gstatic.com/generate_204).
- GUI state: one operation at a time (`ev.exclusive`), buttons disabled while running, every failure shown (no catch-and-ignore); start/stop no longer reload forms (unsaved edits kept; only the Main switch widget is synced); status polling never re-renders forms.
- New RPC `resources` (read ACL). VLESS URL modal warns about committed-vs-staged edits; "QR support unavailable. Install luci-lib-uqr to enable QR."

## 0.5.0 final GUI pass

Same version 0.5.0-r1 (not released yet), GUI/UX only, runtime unchanged.
- Node List: sections Servers / URL Subscriptions / URL Test Groups; page toolbar Import VLESS URL · Test all servers · Add VLESS; no service controls; one-line status bar; VLESS editor is one flat form (no internal tabs) with conditional fields; modal Save commits immediately (also Edit, subscriptions, groups, rules; delete commits too); no QR in the add/save flow (Copy keeps URL + optional QR).
- Row actions Use / Test / URL Test / Copy / ↑ / ↓ / Edit / Delete with natural-width compact buttons (shared `ev.pageStyle()`); no horizontal overflow at 1280 and 1024 px, no clipped buttons (checked in headless Chromium).
- URL Subscriptions: Name, URL, Nodes, Status (Updated = subscribe.lua stored the content md5 / Not updated yet), actions Update · Delete nodes · Edit · Delete, Add subscription + Update all subscriptions inside the section. User-Agent: Default (curl, unchanged behaviour) / HAPP / Custom → existing option `subscribe_list.user_agent`, which subscribe.lua already sends as `--user-agent`; custom values restricted to safe characters.
- HAPP verified on the real request path: local HTTP server logged `User-Agent: HAPP` (Default: `curl/<version>`).
- URL Test Groups: Name, Servers, Test URL, Status (Active / Selected (stopped) / Used by N / Inactive), Use · Edit · Delete; live results only when groups exist, compact notice when not running.
- Rule editor: one form Name → Conditions → Target; condition rows "type | value | ×"; Domain Resource is a dropdown (RUSSIA / PROXY, "+ resource" for more); prepared rules: RUSSIA → Direct, PROXY/QUIC/UDP → the currently selected VLESS/group (`"target": "@active"` in the manifest, resolved when the user clicks Add prepared rule).
- Settings sections: DNS / Forwarding / Advanced.

## 0.5.0-r2 release-candidate pass

Bugfixes and safety changes only; the backend is unchanged except for one rpcd guard.

- Delete now asks for confirmation (`ev.confirm`: Cancel or Delete) for a server, a subscription, "Delete nodes", a URL Test group and a rule. Cancel changes nothing. Servers and groups that are still in use are refused before the dialog, as before. LOCAL.
- Fixed stale row ids after a delete. `uci commit` renumbers anonymous sections (URL subscriptions, `cfgXXXXXX`), so the page kept ids that no longer existed. `ev.saveAndCommit` now reloads the committed config and re-renders the maps that were just saved (no unsaved data is involved). LOCAL: the page ids and `uci -X` ids match after a delete.
- Node List: the "URL Test live results" panel vanished after any save that re-rendered the map. It is now re-placed after every re-render. LOCAL.
- Node List: added a client-side filter box in the toolbar that filters the Servers table by name, address or status text. It is display only. LOCAL.
- rpcd `subscribe truncate` is refused while a subscription update is running (lock `/var/lock/easy_vless_subscribe.lock`). Before this fix, both could rewrite the node list, and "removed" could come out negative. LOCAL.
- Validation doc: `claude/tr3000-rc-0.5.0.md` holds exact router commands, all UNVERIFIED: backup, upgrade, resource md5s, lifecycle, routing, rollback and a GUI checklist.

## Target

Cudy TR3000 v1 (primary test router). WR3000E is the minimal resource baseline. The package stays generic OpenWrt (no device-specific code).

## OpenWrt

| | |
|---|---|
| Version | 24.10.3 |
| Revision | r28872-daca7c049b |
| Target | mediatek/filogic |
| Architecture | aarch64_cortex-a53 |
| Kernel | 6.6.104 |
| LuCI | openwrt-24.10 branch (25.311.74441~90493e0) |

## Installed Engine

- `sing-box-tiny` 1.12.22-r1, `/usr/bin/sing-box`, `Provides: sing-box`
- Tags: `with_gvisor with_quic with_utls with_clash_api`
- Easy VLESS requires sing-box >= **1.12.0** (`EV_SINGBOX_MIN_VERSION`, utils.sh); `easy-vless-sing-box` depends on the virtual `sing-box`, never on `sing-box-tiny`.

## Installed Packages

Verified on TR3000 by the user (0.4.0-r1): `easy-vless`, `easy-vless-sing-box`, `luci-app-easy-vless` 0.4.0-r1, `sing-box-tiny 1.12.22-r1`, `kmod-nf-tproxy`, `kmod-nft-tproxy`, `kmod-nf-socket`, `kmod-nft-socket`.
TODO: full `opkg list-installed` of TR3000 not captured yet.

## Storage Baseline

- Overlay ≈ 44.6 MiB total, ≈ 25 MiB free with Easy VLESS 0.4.x installed (TR3000, user measurement).
- IPK sizes 0.5.0-r2 (offline build, LOCAL): easy-vless 69 292 B (includes resources 15.1 KB), easy-vless-sing-box 16 091 B, luci-app-easy-vless 34 317 B, easy-vless-xray 12 608 B, easy-vless-geodata 953 B. The resources inside the IPK are byte-identical to `reference/domains`.

## RAM Baseline

- ≈ 497 MiB total, ≈ 355 MiB available before sing-box starts (TR3000, user measurement).
- sing-box RSS in LOCAL harness (x86_64, main router with 5 rules + URL Test group): ≈ 33–35 MiB. TR3000 value: not measured yet.

## Architecture

| Package | Content | Depends |
|---|---|---|
| `easy-vless` | runtime: app.sh, nftables.sh, utils.sh, test.sh, subscribe.lua, api.lua, init/hotplug/uci-defaults, prepared resources (`/usr/share/easy_vless/resources/`) | no sing-box, no geodata, no xray |
| `easy-vless-sing-box` | util_sing-box.lua, clash_api.lua | `+easy-vless`, virtual `sing-box` |
| `luci-app-easy-vless` | LuCI JS views, rpcd plugin `luci.easy_vless`, ACL, menu | `+easy-vless +luci-base +rpcd` |
| `easy-vless-geodata` | meta package | `+easy-vless +geoview +v2ray-geoip +v2ray-geosite` (optional) |
| `easy-vless-xray` | util_xray.lua | `+easy-vless xray-core` (optional, not used by MVP, no UI) |

UCI model (unchanged, PassWall2-derived): `global.enabled` (main switch), `global.node` (main node: server / URL Test group / `main_router`), `nodes` sections (`protocol=vless` server, `_urltest` group, `_shunt` = `main_router`), `shunt_rules` (conditions only; section order = priority), `main_router.<rule id>` = target of that rule, `main_router.default_node` = Default target, `subscribe_list`. Targets: `_direct`, `_blackhole`, `_default` (rules only), server id, group id. Section ids created by LuCI are random named ids (stable across saves/reordering).

Routing mode: `routing_mode=singbox` (default, only implemented mode); `nftset` is rejected by app.sh with a clear message. dnsmasq-full is never installed/removed automatically.

## Resources

- Directory (stable, documented): `/usr/share/easy_vless/resources/`
  - `manifest.json`: `{ "version": 1, "resources": [ { "id", "name", "type", "path" (relative), "description" } ], "rule_templates": [ { "id", "remarks", "network", "port", "domain_resource": [ids], "target" } ] }`
  - `domains/russia.txt` (id `russia`, name RUSSIA, 1 entry: `regexp:\.ru$`)
  - `domains/proxy.txt` (id `proxy`, name PROXY, 982 entries: `regexp:\.com$` + domains)
- Source of truth: `D:\Projects\EasyVLESS\reference\domains\{proxy,russia}.txt`, copied byte-for-byte (CRLF kept; `.gitattributes` marks them `-text -whitespace`). Never shortened/filtered.
- Line syntax = domain_list syntax: plain = keyword, `domain:`, `full:`, `regexp:`, `geosite:` (geodata), `#` comment.
- UCI: `list domain_resource '<id>'` in `shunt_rules`; content is never copied into UCI or JS.
- Backend: `api.lua` `get_resource_manifest / get_resource / rule_domain_list / resources_json / resource_file`; `util_sing-box.lua` and `util_xray.lua` call `api.rule_domain_list(e)` at the start of every shunt rule; `app.sh check_routing_config` validates ids and scans resource files for geodata entries.
- GUI: rpcd `resources` → Rule Manage (Resources table, Domain Resource condition with entry counts).
- Templates: RUSSIA (resource russia, TCP+UDP, target Direct), PROXY (resource proxy), QUIC (UDP + port 443), UDP (UDP). Added only by an explicit "Add prepared rule" click; the future Wizard can reuse them.

## Main UI

Menu: **Main · Node List · Rule Manage · Settings** (no URL Test tab).
Main (`main.js`): status cards (Core Running/Stopped/Starting + PID, Main switch, Active node + Default, sing-box version, RSS, firewall table, routing mode, recent log); the only place with Save & Start / Stop / Check config; form: Main switch, Node (Main Router (shunt) / servers / groups), one shunt entry per rule (Rule Manage order) + Default, Localhost Proxy, Client Proxy; Connection test table (Target, Used by, Result, Latency, Response/error, Test) for every server used as a target. Footer Save & Apply = PassWall2 semantics (switch on → check + start, off → stop); Save = commit only.
LOCAL: verified (0.5.0). TR3000: 0.4.0 Main verified by the user; 0.5.0 UNVERIFIED.

## Node List

`servers.js`: toolbar Import VLESS URL · Test all servers · Add VLESS; Servers grid (Name, Address, Port, Transport, Security, Status) with Use / Test / URL Test / Copy / ↑ / ↓ / Edit / Delete; URL Subscriptions (Name, URL, Nodes, Status; Update / Delete nodes / Edit / Delete; Add subscription, Update all subscriptions; User-Agent Default/HAPP/Custom); URL Test Groups (Name, Servers, Test URL, Status; Use / Edit / Delete) + live results. Status = real usage (Active / Selected (stopped) / Active (group) / Used by N / Inactive) + last Server Test / URL Test. Delete refused while referenced. Empty sections are one line.
VLESS editor (flat form): Name, Address, Port, UUID, Transport (+ WS host/path, gRPC service, HTTPUpgrade host/path), TLS, Reality, SNI, uTLS, Fingerprint, Public Key, Short ID, Flow, Allow insecure — shown only when relevant. Save commits the server.
Copy = VLESS URL modal (URL from UCI, Copy, optional QR via luci-lib-uqr, warning about staged edits). QR is never part of add/save.
LOCAL: verified (add, save, edit, copy, test, URL test, import with parsed table, subscription add/update/HAPP/custom/default UA/delete nodes, group add). TR3000: 0.4.0 verified by the user; 0.5.0 UNVERIFIED.

## Rules

`rules.js` (Rule Manage): list Name / Order / Conditions summary / Target with ↑ ↓ Edit Delete, "Add rule", "Add prepared rule" (templates), Resources table.
Rule editor (one form: Name, Conditions, Target), structured Conditions: condition types Domain Resource, Domain (manual), IP, Network, Destination port, Source, Source port, Protocol (http/tls/quic/bittorrent), Inbound (tproxy/socks) — exactly the fields util_sing-box.lua turns into a route rule. Each type once; invalid values are shown inside the editor and block saving.
Semantics (sing-box, shown in the editor): all condition types must match; Domain Resource, Domain and IP are alternatives. Order = UCI section order = sing-box rule order (first match wins). No enable/disable toggle (not in the backend): a rule is inactive when its target is "Not used".
UCI formats: `domain_resource` list; `protocol`/`inbound`/`source` space separated; `network` `tcp,udp`|`tcp`|`udp`; `port`/`sourcePort` comma list with `from:to`; `domain_list`/`ip_list` one per line.
LOCAL: generated sing-box `route.rules` match the UI rules in order (resource rule → domain_regex + 981 keywords for PROXY; RUSSIA → `\.ru$`); sing-box check passes; unknown resource → clear refusal. TR3000: UNVERIFIED.

## Shunt

Targets are chosen on Main (and per rule in Rule Manage — same value `main_router.<rule id>`): Not used, Default target, Direct, servers, URL Test groups, Block (blackhole). Default entry = `main_router.default_node`. Prepared model (RUSSIA → Direct, PROXY/QUIC/UDP/Default → a VLESS node) is created only by the user (templates) or later by the Wizard; nothing is created automatically.

## DNS

Settings → DNS: direct DNS (auto/UDP/TCP + server), direct query strategy, remote DNS protocol TCP/UDP/DoT/DoH (QUIC/HTTP3 exist in runtime but are not exposed), remote DNS server / DoH URL, EDNS client subnet, remote DNS outbound, FakeDNS, remote query strategy, Domain Override (`dns_hosts`), DNS Redirect. Runtime DNS/FakeDNS/hijack-dns/dnsmasq redirect unchanged. LOCAL: DoH config passes sing-box check. TR3000: UNVERIFIED for 0.4.0 (0.3.x DNS worked on TR3000 per user).

Forwarding: TCP/UDP no-redir ports, TCP/UDP redir ports, TCP proxy way TPROXY/REDIRECT, IPv6 TProxy, ICMP hijack. Other: routing mode, log level, sing-box log, Clash API port, node SOCKS port/bind local, delay start.

## Tests

- **Server Test** — default URL exactly `https://www.gstatic.com/generate_204`. rpcd `urltest_node {node}` → `test.sh url_test_node` → `app.sh run_socks` starts a temporary sing-box with the node's VLESS outbound + local SOCKS → `curl -I` through it → `http_code:time:exitcode:errormsg` → PASS (200/204) / FAIL with the real reason. Not a TCP connect; works whether the service runs or not.
- **URL Test (groups)** — default URL exactly `https://x.com`. `_urltest` node → sing-box `urltest` outbound; results via Clash API (`clash_api.lua groups/test`). Live only while running.
- **URL Test (per node, 0.5.0)** — same temporary-instance mechanism as the Server Test with `url=https://x.com`; any HTTP answer = reachable (like sing-box urltest).
- LOCAL: mechanisms verified with local VLESS servers and a local probe URL. The sandbox egress blocks www.gstatic.com (HTTP 403 / TLS error) and answers x.com with 403, so real-URL results in the sandbox are environment artefacts. TR3000: Server Test and URL Test verified by the user on 0.4.0; per-node URL Test UNVERIFIED.

## RPC

ubus object `luci.easy_vless`: `status {log_from}`, `check {node}`, `start`, `stop`, `import {links}` (returns found/added/skipped + parsed `nodes`), `subscribe {action, id}`, `urltest_node {node, url?}`, `groups`, `group_test {group}`, `resources` (0.5.0).
ACL: read `status check groups resources` + uci easy_vless; write `start stop import subscribe urltest_node group_test` + ubus `uci commit` + uci easy_vless.

## Lifecycle

- **check** (`app.sh check [node]`): generates the config exactly like start into `/tmp/etc/easy_vless_check/`, runs `sing-box check`; no firewall/routing/service changes. UI: PASSED/FAILED + sing-box output.
- **start** (rpcd `start`): check → on success `enabled=1`, detached `/etc/init.d/easy_vless restart`; on failure `enabled=0`, nothing touched. UI polls `status` (busy lock `/var/lock/easy_vless.lock`, PID change) and shows Running (PID, version, firewall, RSS) or the failure with the log written since the start.
- **stop**: `enabled=0`, detached stop; removes sing-box, PID file, nft table `inet easy_vless`, ip rule/route table 998, dnsmasq changes, Clash API state, temp files.
- **restart**: stop + start under the init lock.
- **rollback**: sing-box dying right after start → app.sh rollback (stop + cleanup), UI reports "rolled back".
- LOCAL (0.5.0): rpcd start → TPROXY traffic reaches the VLESS server → restart → stop → start → kill -9 → stop, all clean; `/etc/init.d/easy_vless start|stop|restart|enable|enabled|disable` work (S99/K15 links); UI Save & Start / Stop / crash rollback.
- LOCAL (0.4.0): start → traffic via TPROXY → restart → stop → start → kill -9 → stop: clean each time; UI start/stop/crash-rollback flows. TR3000: 0.3.x lifecycle verified by user earlier; 0.4.0 UNVERIFIED.

## Packaging

- Core postinst (since 0.3.0-r2): `/etc/uci-defaults/easy-vless` is executed and removed only by OpenWrt `default_postinst`; `postinst-pkg` only does `/etc/init.d/easy_vless enable` + LuCI index cache cleanup, and nothing under `IPKG_INSTROOT`.
- uci-defaults: firewall include, ucitrack, dhcp localuse, default config copy, upgrade migration (routing_mode, clash_api_port, main_router).
- Conffiles: `/etc/config/easy_vless`, `/usr/share/easy_vless/direct_ip`.
- luci-app postinst/postrm reload rpcd (new RPC methods/ACL need it).
- 0.5.0 core IPK contains `usr/share/easy_vless/resources/{manifest.json,domains/proxy.txt,domains/russia.txt}` (0644, root); CI verifies them. No UCI migration: 0.4.x configs load unchanged (`domain_resource` is optional).

## Build

- Canonical: GitHub Actions `.github/workflows/build.yml` (official OpenWrt 24.10.3 mediatek/filogic SDK, standalone package build, per-package control/content checks incl. resources, 5 artifacts). 0.4.0 was built there by the user.
- 0.5.0-r1/r2: built OFFLINE in the sandbox (harness only: `RSTRIP=true`, because there is no cross toolchain) with the real OpenWrt `package.mk`/`ipkg-build`; **not yet built by SDK/CI**.

## Resolved Bugs

BUG: status polling / start / stop destroyed unsaved form edits
SYMPTOM: after Stop/Start (0.4.0) the Main form was reloaded and unsaved changes were lost.
ROOT CAUSE: `reloadMaps` unloaded the UCI cache to show the new main switch value.
FIX: `syncSwitch` only sets the Main switch widget; forms are never re-rendered by polling or service operations.
FILES: common.js (0.5.0)

BUG: parallel operations / silent handler failures
SYMPTOM: several Start/Test/Update clicks could run at once; some handler errors were swallowed (`.catch(function(){})`).
ROOT CAUSE: no operation guard; catch-and-ignore in handlers.
FIX: `ev.exclusive` (one operation at a time, clear notice), `ev.reportError` for every failure.
FILES: common.js, main.js, servers.js, rules.js (0.5.0)

BUG: condition editor validation invisible
SYMPTOM: invalid rule condition blocked the modal Save without a message.
ROOT CAUSE: LuCI's modal save only highlights its own widgets.
FIX: the editor shows the validation error inline.
FILES: rules.js (0.5.0)

BUG: LuCI saves silently failing (Check config / Save & Start / Use did nothing)
SYMPTOM: buttons "did nothing"; direct `ubus call luci.easy_vless check` worked.
ROOT CAUSE: views commit with ubus `uci commit`; luci-base's ACL does not grant it and the app ACL did not either → rejected promise swallowed by the button handler. The sandbox harness had not enforced ACLs.
FIX: ACL write `"ubus": {"uci": ["commit"]}`; all RPC calls wrapped (`ev.safe`) and save errors shown; harness now enforces ACLs; smoke test checks the ACL.
FILES: luci/root/usr/share/rpcd/acl.d/luci-app-easy-vless.json, common.js, tests/tr3000-slice-smoke.sh (0.4.0)

BUG: footer Save & Apply bypassed the sing-box check
SYMPTOM: LuCI default "Save & Apply" used `uci apply` (ucitrack restart) without check.
ROOT CAUSE: views did not override handleSaveApply/handleSave.
FIX: every view overrides them with commit + check/start (or stop).
FILES: view/easy_vless/*.js, common.js (0.4.0)

BUG: failed check left the main switch on
SYMPTOM: after "Not started: check failed" the committed config had enabled=1 (boot would try it).
ROOT CAUSE: Save & Apply committed the form value before rpcd `start` checked.
FIX: rpcd `start` sets enabled=0 when the check fails.
FILES: luci.easy_vless (0.4.0)

BUG: Server Test gave no reason
SYMPTOM: FAIL "HTTP 000" only.
ROOT CAUSE: test.sh returned only http_code:time.
FIX: curl exit code + error message returned and mapped to readable reasons.
FILES: test.sh, luci.easy_vless (0.4.0)

BUG: double uci-defaults execution (0.3.0-r1)
SYMPTOM: "can't open /etc/uci-defaults/easy-vless" during opkg install on TR3000.
ROOT CAUSE: postinst-pkg sourced/removed the file after OpenWrt `default_postinst` had already run and removed it.
FIX: postinst-pkg no longer touches uci-defaults.
FILES: Makefile (0.3.0-r2)

BUG: PID before queue
SYMPTOM: PID file pointed at a wrong/not yet started process.
ROOT CAUSE: PID written before `run_process_queue` started sing-box.
FIX: PID written after the real start, validated via /proc/<pid>/cmdline before kill.
FILES: app.sh

BUG: leftover nft table
SYMPTOM: restart failed / rules stayed after stop.
ROOT CAUSE: stop did not delete table `inet easy_vless`.
FIX: nftables.sh stop deletes the table.
FILES: nftables.sh

BUG: rollback incomplete
SYMPTOM: after an immediate sing-box crash firewall/routing state remained.
ROOT CAUSE: rollback called nftables.sh's `stop` instead of the full app stop/cleanup.
FIX: rollback runs the complete stop path.
FILES: app.sh

BUG: missing direct_ip / lease2hosts.sh
SYMPTOM: start errors / missing hosts integration.
ROOT CAUSE: files referenced by the runtime were not ported.
FIX: files added and packaged (direct_ip as conffile).
FILES: root/usr/share/easy_vless/direct_ip, lease2hosts.sh, Makefile

BUG: test while stopped
SYMPTOM: Server Test failed when Easy VLESS was stopped.
ROOT CAUSE: `ln_run` used TMP_BIN_PATH that exists only while running.
FIX: ln_run creates the directory.
FILES: utils.sh

BUG: TLS allowInsecure on import
SYMPTOM: imported nodes skipped certificate validation.
ROOT CAUSE: PassWall2 subscribe defaults forced allowInsecure.
FIX: keep the link's flag; global/per-subscription default 0.
FILES: subscribe.lua, 0_default_config

BUG: sing-box 1.14 gate
SYMPTOM: sing-box-tiny 1.12.22 rejected.
ROOT CAUSE: upstream-derived minimum version 1.14.
FIX: minimum 1.12.0.
FILES: utils.sh, app.sh, util_sing-box.lua

BUG: latency measured the local SOCKS handshake
SYMPTOM: unrealistically small Server Test latency.
ROOT CAUSE: curl time_pretransfer.
FIX: time_starttransfer.
FILES: test.sh

BUG: TLS flag default not saved / rule enable flag lost (0.3 LuCI)
SYMPTOM: new server without TLS in UCI; rules toggled off after modal save.
ROOT CAUSE: Flag equal to default is not written; toggle stored in a modal.
FIX: explicit defaults on add; rule activation = target on Main (0.4.0 model).
FILES: servers.js, rules.js, main.js

## Known Limitations

- Test results are not persisted (per page load); URL Test group data exists only while running.
- Node Config has no "From Share URL" inside the modal (import is via Import VLESS URL, single parser = subscribe.lua).
- "Export Config File" not implemented (no correct standalone client config in the backend) — no button.
- QR code needs the optional `luci-lib-uqr`.
- Subscription sections are anonymous UCI sections (PassWall2 model): their cfg ids can change after other subscriptions are deleted; nothing references them by id.
- A start that passes the check but whose sing-box dies immediately is rolled back, but the main switch stays on (status shows "main switch is on, but not running").
- Resources are read-only files; no in-GUI resource editor (manual domains per rule remain available).
- Resource domains are embedded per rule in the generated config (route rule + DNS rules, like manual domain lists); fine for the current sizes (PROXY ≈ 14 KB).
- `global_other.url_test_url` overrides the Server Test URL but has no UI. Remote DNS QUIC/HTTP3 not exposed.

## Not Implemented

- Installer / GitHub auto-installer
- Updater / self-updater
- Wizard (first run; would create RUSSIA/PROXY/QUIC/UDP rules from the manifest templates and assign VLESS #1)
- nftset routing mode (dnsmasq → nftset → TPROXY)
- automatic online resource updater
- Xray UI; server mode; other protocols
- export of sing-box config file

## Future Tasks

- SDK/CI build of 0.5.0-r2 and TR3000 regression (upgrade 0.4→0.5 with config backup, resources installed/visible, rules with resources, Main/Node List/Rule Manage/Settings, Add VLESS, subscriptions with HAPP, Start/Stop/Restart/boot, Server Test, URL Test, groups)
- record full `opkg list-installed` of TR3000
- small bugs / polish after TR3000 feedback
- Wizard, installer/updater, nftset, resource updater (separate stages)

## Last Verified Commit

- Last commit on `main` (user): `b1480ca83dcb1a171dfe8e7a29821425e5444be8` "feat: consolidate Easy VLESS MVP" (0.4.0-r1, TR3000-verified by the user).
- 0.5.0-r1 + r2 changes are delivered to the working folder, not committed. Replace this line with the new hash after commit + CI + TR3000 check.
