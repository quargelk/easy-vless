# Easy VLESS Current State

Canonical handoff. Read this first; work only in the area a task touches; do not re-investigate the resolved bugs below unless a new symptom points at them. Update this file after substantial changes.

Status legend: **LOCAL** = verified in the Claude sandbox harness (x86_64 container: real sing-box 1.12.22, real nftables/TPROXY, real rpcd/ubus/uci, LuCI JS in headless Chromium, stubs for fw4/dnsmasq/netifd). **TR3000** = verified on the real router. **UNVERIFIED** = neither.

## Version

- Packages: **0.4.0-r1** (this pass; previous released: 0.3.0-r2)
- Repository: https://github.com/quargelk/easy-vless, branch `main`
- Upstream/reference: PassWall2 25.5.15-1, commit 394f3842969161ddd888187e72db4b493b3310b4

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

Known on TR3000 (from user reports): `easy-vless`, `easy-vless-sing-box`, `luci-app-easy-vless` (0.3.0-r2), `sing-box-tiny 1.12.22-r1`, `kmod-nf-tproxy`, `kmod-nft-tproxy`, `kmod-nf-socket`, `kmod-nft-socket`.
TODO (not captured yet): full `opkg list-installed` of TR3000 — record it here on the next router session.

## Storage Baseline

- Overlay total ≈ 44.6 MiB; ≈ 24.9 MiB free after installing Easy VLESS 0.3.0-r2 MVP (TR3000, user measurement).
- IPK sizes 0.4.0-r1 (offline build, see Build): easy-vless 61 114 B, easy-vless-sing-box 16 035 B, luci-app-easy-vless 25 422 B, easy-vless-xray 12 548 B, easy-vless-geodata 953 B.

## RAM Baseline

- ≈ 497 MiB total, ≈ 355 MiB available before sing-box starts (TR3000, user measurement).
- sing-box RSS in LOCAL harness (x86_64, main router with 5 rules + URL Test group): ≈ 33–35 MiB. TR3000 value: not measured yet.

## Architecture

| Package | Content | Depends |
|---|---|---|
| `easy-vless` | runtime: app.sh, nftables.sh, utils.sh, test.sh, subscribe.lua, api.lua, init/hotplug/uci-defaults | no sing-box, no geodata, no xray |
| `easy-vless-sing-box` | util_sing-box.lua, clash_api.lua | `+easy-vless`, virtual `sing-box` |
| `luci-app-easy-vless` | LuCI JS views, rpcd plugin `luci.easy_vless`, ACL, menu | `+easy-vless +luci-base +rpcd` |
| `easy-vless-geodata` | meta package | `+easy-vless +geoview +v2ray-geoip +v2ray-geosite` (optional) |
| `easy-vless-xray` | util_xray.lua | `+easy-vless xray-core` (optional, not used by MVP, no UI) |

UCI model (unchanged, PassWall2-derived): `global.enabled` (main switch), `global.node` (main node: server / URL Test group / `main_router`), `nodes` sections (`protocol=vless` server, `_urltest` group, `_shunt` = `main_router`), `shunt_rules` (conditions only; section order = priority), `main_router.<rule id>` = target of that rule, `main_router.default_node` = Default target, `subscribe_list`. Targets: `_direct`, `_blackhole`, `_default` (rules only), server id, group id. Section ids created by LuCI are random named ids (stable across saves/reordering).

Routing mode: `routing_mode=singbox` (default, only implemented mode); `nftset` is rejected by app.sh with a clear message. dnsmasq-full is never installed/removed automatically.

## Main UI

Menu: **Main · Node List · Rule Manage · Settings** (no separate URL Test tab).
Main (`view/easy_vless/main.js`): status cards (Core Running/Stopped/Starting, Main switch, Active node + Default, sing-box version, RSS, firewall table, routing mode, recent log), buttons Save & Start / Stop / Check config; form: Main switch, Node (Main Router (shunt) / servers / groups), one shunt entry per rule (in Rule Manage order) + Default, Localhost Proxy, Client Proxy; Connection test table (Server Test of every server used as a target). Footer Save & Apply = PassWall2 semantics (switch on → check + start, off → stop); Save = commit only.
LOCAL: all of this incl. no JS errors. TR3000: UNVERIFIED.

## Node List

`view/easy_vless/servers.js`: Servers grid (Name, Address, Port, Transport, Security, Status, Test, URL Test) with Use / Test / URL (copy + QR) / ↑ / ↓ / Edit / Delete; Add server; Import VLESS URL (bulk; result = found/imported/skipped + parser log); Test all servers. Delete is refused (with the list of references) while a server/group is used. URL Test groups grid (Use/Edit/Delete) + live results (Clash API) with "Test all servers now" and "Use this server". Subscriptions grid (Update / Delete nodes / Edit / Delete, Update all) using the existing subscribe.lua (VLESS only; other types skipped and logged).
Node Config modal: Name, Address, Port, UUID (masked), Transport TCP/WS/gRPC/HTTPUpgrade, Flow, WS host/path, gRPC service, HTTPUpgrade host/path, TLS, Reality, SNI, public key, short ID, uTLS/fingerprint, allowInsecure (default off); conditional visibility.
QR: rendered by `uqr` if the optional package `luci-lib-uqr` is installed, otherwise a hint (no new dependency).
LOCAL: Use, Test (PASS/FAIL), Up/Down (UCI order), URL + QR, import 4 links → 2 imported/2 skipped, delete-in-use refused, live URL Test results, subscription update/truncate via RPC. TR3000: UNVERIFIED.

## Rules

`view/easy_vless/rules.js` (Rule Manage): list Name / Order / Conditions summary / Target with ↑ ↓ Edit Delete; modal tabs Rule (Name, Target) and Conditions (Protocol http/tls/quic/bittorrent, Inbound tproxy/socks, Network, Source list, Source port, Port, Domain with prefix help, IP). Stored exactly as util_sing-box.lua parses: protocol/inbound/source space-separated strings, network `tcp,udp`, ports comma list with `from:to` ranges (validated 1–65535), domain_list/ip_list one entry per line (`#` comments). Domain prefixes: plain = keyword, `domain:` suffix, `full:`, `regexp:`, `geosite:` (needs easy-vless-geodata), `rule-set:`/`rs:`.
Source-port condition: PassWall2 ships it commented out; enabled in util_sing-box.lua (sing-box 1.12 `source_port`/`source_port_range`).
LOCAL: generated `route.rules` match the UI rules 1:1 in order (checked for RUSSIA/Proxy/QUIC/UDP/source-port/protocol/inbound rules and a UI-created rule); sing-box check passes; geosite without geodata → clear refusal. TR3000: UNVERIFIED.

## Shunt

Shunt targets are chosen on Main (and also editable per rule in Rule Manage — same UCI value `main_router.<rule id>`). Values: Not used (rule inactive), Default target, Direct, servers, URL Test groups, Block. Default entry = `main_router.default_node`. Nothing is created automatically: RUSSIA/Proxy/QUIC/UDP/Default entries exist only if rules exist (future Wizard creates them).

## DNS

Settings → DNS: direct DNS (auto/UDP/TCP + server), direct query strategy, remote DNS protocol TCP/UDP/DoT/DoH (QUIC/HTTP3 exist in runtime but are not exposed), remote DNS server / DoH URL, EDNS client subnet, remote DNS outbound, FakeDNS, remote query strategy, Domain Override (`dns_hosts`), DNS Redirect. Runtime DNS/FakeDNS/hijack-dns/dnsmasq redirect unchanged. LOCAL: DoH config passes sing-box check. TR3000: UNVERIFIED for 0.4.0 (0.3.x DNS worked on TR3000 per user).

Forwarding: TCP/UDP no-redir ports, TCP/UDP redir ports, TCP proxy way TPROXY/REDIRECT, IPv6 TProxy, ICMP hijack. Other: routing mode, log level, sing-box log, Clash API port, node SOCKS port/bind local, delay start.

## Tests

- **Server Test** — default URL exactly `https://www.gstatic.com/generate_204`. Mechanism: rpcd `urltest_node` → `test.sh url_test_node` → `app.sh run_socks` starts a temporary sing-box with the node's real VLESS outbound and a local SOCKS inbound → `curl -I` through it → `http_code:time_starttransfer:exitcode:errormsg` → UI shows PASS/FAIL, latency, HTTP status, real error (timeout, instance did not start, no answer through VLESS, TLS error…). Not a TCP connect. Works while the service is stopped or running. (`global_other.url_test_url` can override the URL; not exposed in UI.)
- **URL Test** — default URL exactly `https://x.com`. Mechanism: `_urltest` node → sing-box `urltest` outbound (`gen_urltest_outbound`); results via the sing-box Clash API (`experimental.clash_api`, 127.0.0.1:clash_api_port, secret in `/tmp/etc/easy_vless/clash_api`) read by `clash_api.lua` (`groups`, `test` = GET `/proxies/<member>/delay` per member). Live only while Easy VLESS runs and the group is part of the running config.
- LOCAL: both verified with local VLESS test servers (TCP/WS/gRPC/HTTPUpgrade/Reality). Note: the sandbox egress blocks www.gstatic.com (HTTP 403), so LOCAL PASS results used a local probe URL override; with the real default URL the sandbox shows FAIL HTTP 403 (environment, not code).

## RPC

ubus object `luci.easy_vless` (`/usr/libexec/rpcd/luci.easy_vless`): `status {log_from}`, `check {node}`, `start`, `stop`, `import {links}`, `subscribe {action: update|truncate, id}`, `urltest_node {node}`, `groups`, `group_test {group}`. Every method returns JSON with a reason on failure; LuCI wraps every call (`ev.safe`) so RPC errors are shown, never swallowed.
ACL `/usr/share/rpcd/acl.d/luci-app-easy-vless.json`: read `status check groups` + uci easy_vless; write `start stop import subscribe urltest_node group_test` + ubus `uci commit` + uci easy_vless.

## Lifecycle

- **check** (`app.sh check [node]`): generates the config exactly like start into `/tmp/etc/easy_vless_check/`, runs `sing-box check`; no firewall/routing/service changes. UI: PASSED/FAILED + sing-box output.
- **start** (rpcd `start`): check → on success `enabled=1`, detached `/etc/init.d/easy_vless restart`; on failure `enabled=0`, nothing touched. UI polls `status` (busy lock `/var/lock/easy_vless.lock`, PID change) and shows Running (PID, version, firewall, RSS) or the failure with the log written since the start.
- **stop**: `enabled=0`, detached stop; removes sing-box, PID file, nft table `inet easy_vless`, ip rule/route table 998, dnsmasq changes, Clash API state, temp files.
- **restart**: stop + start under the init lock.
- **rollback**: sing-box dying right after start → app.sh rollback (stop + cleanup), UI reports "rolled back".
- LOCAL (0.4.0): start → traffic via TPROXY → restart → stop → start → kill -9 → stop: clean each time; UI start/stop/crash-rollback flows. TR3000: 0.3.x lifecycle verified by user earlier; 0.4.0 UNVERIFIED.

## Packaging

- Core postinst (since 0.3.0-r2): `/etc/uci-defaults/easy-vless` is executed and removed only by OpenWrt `default_postinst`; `postinst-pkg` only does `/etc/init.d/easy_vless enable` + LuCI index cache cleanup, and nothing under `IPKG_INSTROOT`.
- uci-defaults: firewall include, ucitrack, dhcp localuse, default config copy, upgrade migration (routing_mode, clash_api_port, main_router).
- Conffiles: `/etc/config/easy_vless`, `/usr/share/easy_vless/direct_ip`.
- luci-app postinst/postrm reload rpcd (new RPC methods/ACL need it).

## Build

- Canonical: GitHub Actions `.github/workflows/build.yml` with the official OpenWrt 24.10.3 mediatek/filogic SDK, standalone `make -C package/easy-vless … clean compile`, verification of control/Depends/Architecture/contents per package, 5 artifacts.
- 0.4.0-r1: built OFFLINE in the sandbox with the real OpenWrt `package.mk`/`ipkg-build` (official SDK not downloadable there). **Not yet built by the SDK/CI** — push and check the workflow run.

## Resolved Bugs

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

- Server/URL Test results are not persisted (per page load); URL Test data exists only while running.
- Node Config has no "From Share URL" inside the modal (import is via Import VLESS URL, single parser = subscribe.lua).
- "Export Config File" not implemented (no backend export of a standalone client config).
- QR code needs the optional `luci-lib-uqr`.
- Server grid is wide on narrow screens (horizontal scroll).
- `global_other.url_test_url` overrides the Server Test URL but has no UI.
- Remote DNS QUIC/HTTP3 not exposed in UI.

## Not Implemented

- Wizard (first run, base rules RUSSIA/Proxy/QUIC/UDP/Default, first VLESS as target)
- installer / updater
- nftset routing mode (dnsmasq → nftset → TPROXY)
- domain resource downloader / prepared domain lists
- Xray UI / Xray usage in MVP
- export of sing-box config file

## Future Tasks

- SDK/CI build of 0.4.0-r1 and TR3000 verification of 0.4.0 (install/upgrade, LuCI, Check, Start/Stop/Restart, rollback, Server Test, URL Test, rules traffic, DNS, UDP, memory)
- record full `opkg list-installed` of TR3000
- GUI polish
- Wizard
- installer/updater
- nftset mode
- domain resources
- optimization

## Last Verified Commit

- Last commit on `main` (user): `eef8c13d9ffb4f45895625acce0fabfbaf4578a3` "fix: correct package postinst" (0.3.0-r2).
- 0.4.0-r1 changes of this pass are delivered to the working folder, not committed yet. Replace this line with the new hash after commit + CI.
