#!/bin/sh
# Easy VLESS - installer / bootstrap scenarios, run inside a fresh
# openwrt/rootfs:x86-64-24.10.3 container by tests/ci/installer-tests.sh:
#   sh installer-scenarios.sh preflight|online|rollback|bootstrap|upgrade
#
# Real OpenWrt primitives are used everywhere (opkg, official feeds and
# archive.openwrt.org, uclient-fetch + libustream-mbedtls, the published
# v0.5.1 GitHub release). Failures are provoked by changing the system the
# same way they happen on a router (feeds, CA certificates, TLS library,
# /etc/openwrt_release, removed opkg). Three fault-injection variables of
# scripts/install.sh are used where the real event cannot be caused safely:
#   EV_TEST_NOW                         clock value (the container cannot
#                                       change the kernel clock)
#   EV_TEST_FAIL_DNSMASQ_INSTALL        dnsmasq-full installation fails
#   EV_TEST_SIGNAL_AFTER_DNSMASQ_REMOVE SIGTERM right after dnsmasq removal
#
# Environment (set by installer-tests.sh): W (repository), DIST (built
# release files), SRV (https://<host>:<port> of the test server, valid
# certificate), SRV_FUTURE (same files, certificate not yet valid),
# TEST_CA (CA certificate of both servers).

W="${W:-/w}"
DIST="${DIST:-$W/dist}"
INST="$W/scripts/install.sh"
V="$(sed -n 's/^EV_VERSION="\(.*\)"$/\1/p' "$INST")"
LOG=/tmp/inst.log
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }
note() { echo "----- $* -----"; }

# inst ARGS...: run the installer, output in $LOG, exit code in $RC
inst() { sh "$INST" "$@" >"$LOG" 2>&1; RC=$?; }
show() { sed 's/^/    | /' "$LOG" | tail -n "${1:-15}"; }
# expect_fail DESCRIPTION PATTERN ARGS...: installer fails and prints PATTERN (ERE)
expect_fail() {
	local d="$1" p="$2"; shift 2
	inst "$@"
	if [ "$RC" != 0 ] && grep -qE -e "$p" "$LOG"; then ok "$d"; else bad "$d (rc=$RC, expected /$p/)"; show; fi
}
# expect_ok DESCRIPTION PATTERN ARGS...: installer succeeds and prints PATTERN
expect_ok() {
	local d="$1" p="$2"; shift 2
	inst "$@"
	if [ "$RC" = 0 ] && grep -qE -e "$p" "$LOG"; then ok "$d"; else bad "$d (rc=$RC, expected /$p/)"; show 30; fi
}
installed() { opkg list-installed 2>/dev/null | awk -v p="$1" '$1 == p { print $3; exit }'; }
check() { if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }
no_leftovers() { check "no temporary installer directory left ($1)" '! ls -d /tmp/easy-vless-install.* >/dev/null 2>&1'; }

prepare() {
	mkdir -p /var/lock /var/run /tmp/log
	opkg update >/tmp/prep.log 2>&1 || { cat /tmp/prep.log; echo "prepare: opkg update failed"; exit 1; }
	# a real router has fw4; the rootfs image does not
	command -v fw4 >/dev/null 2>&1 || opkg install firewall4 >>/tmp/prep.log 2>&1 || { cat /tmp/prep.log; exit 1; }
	[ -n "$V" ] || { echo "cannot read EV_VERSION"; exit 1; }
}
trust_test_ca() { cp "$TEST_CA" /etc/ssl/certs/ev-test-ca.crt; }
untrust_test_ca() { rm -f /etc/ssl/certs/ev-test-ca.crt; }

nothing_installed() {
	check "$1: easy-vless not installed" '[ -z "$(installed easy-vless)" ]'
	check "$1: stock dnsmasq still installed" '[ -n "$(installed dnsmasq)" ] && [ -z "$(installed dnsmasq-full)" ]'
	check "$1: sing-box not installed" '[ -z "$(installed sing-box-tiny)" ]'
}

# ====================================================================== preflight
# Checks and download errors: every case must stop before anything changes.
sc_preflight() {
	note "help and options"
	expect_ok "--help lists every option" "--base-url" --help
	for o in --check --local --base-url --replace-dnsmasq --yes --no-start --bootstrap-opkg --force --help; do
		grep -q -- "$o" "$LOG" && ok "--help documents $o" || bad "--help does not document $o"
	done
	grep -q "Easy VLESS $V installer" "$LOG" && ok "--help shows version $V" || bad "--help version"
	expect_fail "unknown option rejected" "unknown option" --bogus
	expect_fail "http:// base URL rejected" "must be an https:// URL" --base-url http://example.com/x

	note "--check on a clean OpenWrt 24.10.3"
	expect_ok "--check passes" "check finished: no blocking problem found" --check
	grep -q "system time: .* - ok" "$LOG" && ok "--check reports the system time" || bad "time line missing"
	grep -q "HTTPS: uclient-fetch, TLS library and CA certificates present" "$LOG" && ok "--check reports HTTPS readiness" || bad "HTTPS line missing"
	grep -q "will install sing-box-tiny" "$LOG" && ok "--check announces sing-box-tiny" || bad "sing-box-tiny not announced"
	grep -q "replace dnsmasq with dnsmasq-full" "$LOG" && ok "--check announces the dnsmasq replacement" || bad "dnsmasq not announced"

	note "missing utility"
	t="$(command -v sha256sum)"; mv "$t" "$t.off"
	expect_fail "missing sha256sum detected" "required tools missing: sha256sum" --check
	mv "$t.off" "$t"

	note "system time behind (firmware build date, before NTP)"
	EV_TEST_NOW=1758316778 expect_fail "clock at the 24.10.3 build date is refused" "system time is still wrong" --check
	grep -q "trying a one-time NTP synchronisation" "$LOG" && ok "NTP synchronisation attempted" || bad "no NTP attempt"

	note "missing CA certificates"
	mkdir -p /tmp/certs.off && mv /etc/ssl/certs/* /tmp/certs.off/
	expect_fail "missing CA bundle detected before any download" "no CA certificates in /etc/ssl/certs" --check
	mv /tmp/certs.off/* /etc/ssl/certs/

	note "missing TLS library"
	mkdir -p /tmp/tls.off && mv /lib/libustream-ssl.so* /tmp/tls.off/
	expect_fail "missing libustream detected" "no TLS library" --check
	mv /tmp/tls.off/* /lib/

	note "wrong architecture"
	cp /etc/openwrt_release /tmp/openwrt_release.orig
	sed -i "s/^DISTRIB_ARCH=.*/DISTRIB_ARCH='aarch64_cortex-a53'/" /etc/openwrt_release
	expect_fail "architecture mismatch detected" "architecture mismatch: /etc/openwrt_release says aarch64_cortex-a53" --check
	cp /tmp/openwrt_release.orig /etc/openwrt_release

	note "opkg update: required and optional feeds"
	trust_test_ca
	cp /etc/opkg/distfeeds.conf /tmp/distfeeds.orig
	sed -i "s#^src/gz openwrt_base .*#src/gz openwrt_base ${SRV}/nofeed/base#" /etc/opkg/distfeeds.conf
	expect_fail "failing required feed stops the installer" "required package feeds not available: openwrt_base" --check
	cp /tmp/distfeeds.orig /etc/opkg/distfeeds.conf
	sed -i "s#^src/gz openwrt_packages .*#src/gz openwrt_packages https://nonexistent.invalid/packages#" /etc/opkg/distfeeds.conf
	expect_fail "unresolvable required feed stops the installer" "required package feeds not available: openwrt_packages" --check
	cp /tmp/distfeeds.orig /etc/opkg/distfeeds.conf
	sed -i "s#^src/gz openwrt_routing .*#src/gz openwrt_routing ${SRV}/nofeed/routing#" /etc/opkg/distfeeds.conf
	expect_ok "failing optional feed only warns" "optional package feeds not available: openwrt_routing" --check
	cp /tmp/distfeeds.orig /etc/opkg/distfeeds.conf

	note "release downloads (--base-url) - all must fail before any change"
	A="--replace-dnsmasq --yes --no-start"
	# shellcheck disable=SC2086
	expect_fail "certificate not yet valid -> system time diagnosis" "most likely the system time is wrong" --base-url "$SRV_FUTURE/ok" $A
	untrust_test_ca
	# shellcheck disable=SC2086
	expect_fail "untrusted certificate -> CA diagnosis" "is not trusted: the CA certificates are missing" --base-url "$SRV/ok" $A
	trust_test_ca
	# shellcheck disable=SC2086
	expect_fail "missing release asset -> HTTP 404 with URL" "URL: +$SRV/missing/luci-app-easy-vless_${V}_all.ipk" --base-url "$SRV/missing" $A
	grep -q "HTTP 404" "$LOG" && ok "404 explained" || bad "404 not explained"
	# shellcheck disable=SC2086
	expect_fail "tampered package -> checksum mismatch" "checksum mismatch for easy-vless_${V}_all.ipk" --base-url "$SRV/tampered" $A
	# shellcheck disable=SC2086
	expect_fail "SHA256SUMS without the package -> refused" "not listed exactly once in SHA256SUMS" --base-url "$SRV/badsums" $A
	# shellcheck disable=SC2086
	expect_fail "empty download -> refused" "download failed: SHA256SUMS" --base-url "$SRV/empty" $A
	# shellcheck disable=SC2086
	expect_fail "unresolvable release host -> DNS diagnosis" "nonexistent.invalid cannot be resolved|refused by the router itself" --base-url "https://nonexistent.invalid/x" $A

	note "--local errors"
	mkdir -p /tmp/l-empty /tmp/l-old /tmp/l-sums
	# shellcheck disable=SC2086
	expect_fail "--local without SHA256SUMS" "SHA256SUMS not found" --local /tmp/l-empty $A
	for f in "$DIST"/*.ipk; do cp "$f" "/tmp/l-old/$(basename "$f" | sed "s/_${V}_/_0.5.1-r1_/")"; done
	cp "$DIST/SHA256SUMS" /tmp/l-old/
	# shellcheck disable=SC2086
	expect_fail "--local with packages of another version" "easy-vless_${V}_all.ipk not found .*0.5.1-r1" --local /tmp/l-old $A
	cp "$DIST"/*.ipk /tmp/l-sums/ && grep -v "^[0-9a-f]*  easy-vless-sing-box_" "$DIST/SHA256SUMS" >/tmp/l-sums/SHA256SUMS
	# shellcheck disable=SC2086
	expect_fail "--local with an incomplete SHA256SUMS" "easy-vless-sing-box_${V}_all.ipk is not listed exactly once" --local /tmp/l-sums $A
	cp "$DIST"/SHA256SUMS /tmp/l-sums/ && printf 'garbage' >>"/tmp/l-sums/easy-vless_${V}_all.ipk"
	# shellcheck disable=SC2086
	expect_fail "--local with a modified package" "checksum mismatch for easy-vless_${V}_all.ipk" --local /tmp/l-sums $A

	nothing_installed "after all failed runs"
	no_leftovers "preflight"
}

# ====================================================================== online
# Download from an HTTPS server with a real certificate chain, repeated run,
# already installed, preserved configuration.
sc_online() {
	trust_test_ca
	expect_ok "install from HTTPS release URL" "Easy VLESS packages verified against SHA256SUMS" \
		--base-url "$SRV/ok" --replace-dnsmasq --yes --no-start
	for p in easy-vless easy-vless-sing-box luci-app-easy-vless; do
		check "$p $V installed" "[ \"\$(installed $p)\" = \"$V\" ]"
	done
	check "sing-box-tiny installed from the official feed" '[ -n "$(installed sing-box-tiny)" ] && sing-box version >/dev/null'
	check "dnsmasq replaced by dnsmasq-full" '[ -n "$(installed dnsmasq-full)" ] && [ -z "$(installed dnsmasq)" ]'
	check "dnsmasq reports nftset" 'dnsmasq --version | grep -q " nftset"'
	check "DHCP config backup kept" '[ -s /etc/config/dhcp.easy-vless.bak ]'
	check "service enabled" '/etc/init.d/easy_vless enabled'
	no_leftovers "first install"

	note "repeated run, configuration preserved"
	uci set easy_vless.global.ev_test_marker='kept'
	s=$(uci add easy_vless nodes); uci set "easy_vless.$s.remarks=EVTEST node"; uci set "easy_vless.$s.address=198.51.100.7"
	uci commit easy_vless
	before="$(uci export easy_vless | md5sum)"
	expect_ok "second run on an installed system" "installed now: $V" --base-url "$SRV/ok" --replace-dnsmasq --yes --no-start
	check "configuration unchanged by the repeated run" "[ \"\$(uci export easy_vless | md5sum)\" = \"$before\" ]"
	check "one easy-vless package entry" '[ "$(opkg list-installed | grep -c "^easy-vless ")" = 1 ]'
	no_leftovers "repeated run"
}

# ====================================================================== rollback
sc_rollback() {
	dhcp_md5="$(md5sum </etc/config/dhcp)"
	EV_TEST_FAIL_DNSMASQ_INSTALL=1 expect_fail "failed dnsmasq-full installation is rolled back" "dnsmasq was restored" \
		--local "$DIST" --replace-dnsmasq --yes --no-start
	check "stock dnsmasq back after failure" '[ -n "$(installed dnsmasq)" ] && [ -z "$(installed dnsmasq-full)" ] && [ -x /usr/sbin/dnsmasq ]'
	check "DHCP config restored after failure" "[ \"\$(md5sum </etc/config/dhcp)\" = \"$dhcp_md5\" ]"
	check "Easy VLESS not installed after failure" '[ -z "$(installed easy-vless)" ]'
	no_leftovers "failed dnsmasq-full"

	EV_TEST_SIGNAL_AFTER_DNSMASQ_REMOVE=1 expect_fail "interruption after removing dnsmasq is rolled back" "interrupted" \
		--local "$DIST" --replace-dnsmasq --yes --no-start
	grep -q "restoring dnsmasq" "$LOG" && ok "rollback ran on the signal" || bad "no rollback on the signal"
	check "stock dnsmasq back after interruption" '[ -n "$(installed dnsmasq)" ] && [ -z "$(installed dnsmasq-full)" ] && [ -x /usr/sbin/dnsmasq ]'
	check "DHCP config restored after interruption" "[ \"\$(md5sum </etc/config/dhcp)\" = \"$dhcp_md5\" ]"
	no_leftovers "interruption"

	expect_ok "normal run after the rollbacks" "dnsmasq-full installed" --local "$DIST" --replace-dnsmasq --yes --no-start
	check "dnsmasq-full installed at the end" '[ -n "$(installed dnsmasq-full)" ] && dnsmasq --version | grep -q " nftset"'
	check "Easy VLESS $V installed" "[ \"\$(installed easy-vless)\" = \"$V\" ]"
}

# ====================================================================== bootstrap
# README manual bootstrap and installer --bootstrap-opkg on a router whose
# opkg (and usign/openwrt-keyring) were removed.
remove_opkg() {
	opkg remove --force-depends usign openwrt-keyring >/dev/null 2>&1
	opkg remove --force-removal-of-essential-packages opkg >/dev/null 2>&1
	rm -f /bin/opkg /etc/opkg/keys/*
	rm -rf /var/opkg-lists
}
sc_bootstrap() {
	. /etc/openwrt_release
	base="https://archive.openwrt.org/releases/${DISTRIB_RELEASE}/packages/${DISTRIB_ARCH}/base"

	note "README manual bootstrap (same commands, this architecture)"
	opkg remove --force-removal-of-essential-packages opkg >/dev/null 2>&1; rm -f /bin/opkg
	check "opkg removed" '! command -v opkg >/dev/null 2>&1'
	mkdir -p /tmp/opkg-bootstrap && cd /tmp/opkg-bootstrap || exit 1
	wget -q -O Packages "$base/Packages"
	file="$(awk '/^Package: /{p=$2} /^Filename: /{if(p=="opkg")print $2}' Packages)"
	sum="$(awk '/^Package: /{p=$2} /^SHA256sum: /{if(p=="opkg")print $2}' Packages)"
	wget -q "$base/$file"
	check "README: opkg package matches the SHA256 of the index" "[ \"\$(sha256sum '$file' | cut -d' ' -f1)\" = '$sum' ]"
	tar -xvzf opkg_*.ipk >/dev/null && tar -xzf data.tar.gz -C /
	check "README: extracted opkg works (opkg update)" 'opkg update >/tmp/manual-update.log 2>&1'
	cd / && rm -rf /tmp/opkg-bootstrap
	opkg install opkg >/dev/null 2>&1

	note "installer refuses unsafe bootstrap situations"
	remove_opkg
	expect_fail "--check with missing opkg" "--check: opkg is missing" --check
	expect_fail "missing opkg without --bootstrap-opkg (no terminal)" "Run again with --bootstrap-opkg" --local "$DIST" --replace-dnsmasq --yes --no-start
	mv /usr/lib/opkg/status /tmp/status.off
	expect_fail "missing opkg database refused" "opkg package database .* is missing" --bootstrap-opkg --local "$DIST" --replace-dnsmasq --yes --no-start
	mv /tmp/status.off /usr/lib/opkg/status
	mv /etc/opkg/distfeeds.conf /tmp/distfeeds.off
	expect_fail "missing distfeeds.conf refused" "distfeeds.conf is missing" --bootstrap-opkg --local "$DIST" --replace-dnsmasq --yes --no-start
	mv /tmp/distfeeds.off /etc/opkg/distfeeds.conf
	check "nothing extracted by the refused runs" '[ ! -e /bin/opkg ]'

	note "installer --bootstrap-opkg (opkg, usign and keys missing)"
	printf 'dest root /\ndest ram /tmp\nlists_dir ext /var/opkg-lists\noption overlay_root /overlay\noption check_signature\n# ev-test: customised\n' >/etc/opkg.conf
	expect_ok "bootstrap opkg and install" "Easy VLESS packages verified against SHA256SUMS" \
		--bootstrap-opkg --local "$DIST" --replace-dnsmasq --yes --no-start
	for p in opkg usign openwrt-keyring; do
		grep -q "$p .* installed from $base/" "$LOG" && ok "$p bootstrapped from the archive (SHA256 verified)" || bad "$p not bootstrapped"
		check "$p registered in the opkg database" "[ -n \"\$(installed $p)\" ]"
	done
	grep -q "feed index signature verified with the installed keys" "$LOG" && ok "index signature verified after installing the keys" || bad "index signature not verified"
	check "customised /etc/opkg.conf kept" 'grep -q "ev-test: customised" /etc/opkg.conf'
	check "Easy VLESS $V installed after bootstrap" "[ \"\$(installed easy-vless)\" = \"$V\" ]"
	no_leftovers "bootstrap"
}

# ====================================================================== upgrade
# Upgrade from the published 0.5.1-r1 (real GitHub release), then
# uninstall and reinstall.
sc_upgrade() {
	note "install the published 0.5.1-r1 from GitHub"
	wget -q -O /tmp/install-051.sh https://github.com/quargelk/easy-vless/releases/download/v0.5.1/install.sh
	check "v0.5.1 installer downloaded from GitHub over HTTPS" '[ -s /tmp/install-051.sh ] && grep -q "EV_VERSION=\"0.5.1-r1\"" /tmp/install-051.sh'
	sh /tmp/install-051.sh --replace-dnsmasq --yes --no-start >"$LOG" 2>&1; RC=$?
	[ "$RC" = 0 ] && ok "0.5.1-r1 installed from the GitHub release" || { bad "0.5.1-r1 installation (rc=$RC)"; show 30; }
	check "easy-vless 0.5.1-r1 installed" '[ "$(installed easy-vless)" = "0.5.1-r1" ]'

	note "configuration made with 0.5.1-r1"
	s=$(uci add easy_vless subscribe_list)
	uci set "easy_vless.$s.remark=EVTEST sub"; uci set "easy_vless.$s.url=https://example.invalid/evtest-list"
	uci set "easy_vless.$s.user_agent=HAPP"; uci set "easy_vless.$s.hwid=1"
	uci set "easy_vless.$s.auto_update=1"; uci set "easy_vless.$s.auto_update_interval=6"
	n=$(uci add easy_vless nodes)
	uci set "easy_vless.$n.remarks=EVTEST node"; uci set "easy_vless.$n.protocol=vless"; uci set "easy_vless.$n.type=sing-box"
	uci set "easy_vless.$n.address=198.51.100.9"; uci set "easy_vless.$n.port=443"
	uci set "easy_vless.$n.uuid=00000000-0000-4000-8000-000000000009"
	uci set easy_vless.global.enabled=0
	uci commit easy_vless
	mkdir -p /etc/easy_vless && echo "0123456789abcdef0123456789abcdef" >/etc/easy_vless/hwid
	uci export easy_vless >/tmp/cfg-before
	hwid_before="$(cat /etc/easy_vless/hwid)"

	note "upgrade to $V"
	expect_ok "upgrade 0.5.1-r1 -> $V" "installed now: 0.5.1-r1" --local "$DIST" --no-start
	for p in easy-vless easy-vless-sing-box luci-app-easy-vless; do
		check "$p upgraded to $V" "[ \"\$(installed $p)\" = \"$V\" ]"
	done
	uci export easy_vless >/tmp/cfg-after
	if cmp -s /tmp/cfg-before /tmp/cfg-after; then ok "configuration (nodes, subscription, HAPP, HWID flag) unchanged by the upgrade"
	else bad "configuration changed by the upgrade"; diff /tmp/cfg-before /tmp/cfg-after | head -20; fi
	check "HWID unchanged" "[ \"\$(cat /etc/easy_vless/hwid)\" = \"$hwid_before\" ]"
	check "prepared resources match tests/resources.sha256" \
		"grep '  root/' '$W/tests/resources.sha256' | sed 's#  root/#  /#' | sha256sum -c - >/dev/null"
	check "service still enabled" '/etc/init.d/easy_vless enabled'

	note "uninstall and reinstall"
	opkg remove luci-app-easy-vless easy-vless-sing-box easy-vless >"$LOG" 2>&1
	check "packages removed" '[ -z "$(installed easy-vless)" ] && [ ! -e /etc/init.d/easy_vless ]'
	check "fw4 include removed on uninstall" '! uci -q get firewall.easy_vless >/dev/null'
	check "no Easy VLESS nft table left" '! nft list table inet easy_vless >/dev/null 2>&1'
	expect_ok "reinstall after uninstall" "Easy VLESS packages verified" --local "$DIST" --no-start
	check "fw4 include back after reinstall" '[ "$(uci -q get firewall.easy_vless)" = include ]'
	check "easy-vless $V installed again" "[ \"\$(installed easy-vless)\" = \"$V\" ]"
}

case "${1:-}" in
	preflight|online|rollback|bootstrap|upgrade) ;;
	*) echo "usage: $0 preflight|online|rollback|bootstrap|upgrade"; exit 2 ;;
esac
echo "===== scenario $1 (Easy VLESS $V) ====="
prepare
"sc_$1"
echo "===== $1: PASS: $PASS  FAIL: $FAIL ====="
[ "$FAIL" -eq 0 ]
