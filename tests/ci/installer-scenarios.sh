#!/bin/sh
# Easy VLESS - installer / bootstrap scenarios, run inside a fresh
# openwrt/rootfs container (any target/architecture of the CI matrix:
# x86-64 natively, ARM/MIPS rootfs images through QEMU user emulation - the
# real OpenWrt userland of that architecture, nothing is renamed) by
# tests/ci/installer-tests.sh:
#   sh installer-scenarios.sh <scenario>   (see the case statement at the end)
#
# Real OpenWrt primitives are used everywhere (opkg, official feeds and
# archive.openwrt.org, uclient-fetch + libustream-mbedtls, the published
# v0.5.1 GitHub release). Failures are provoked by changing the system the
# same way they happen on a router (feeds, CA certificates, TLS library,
# /etc/openwrt_release, removed opkg). RAM and free space limits are real
# limits of the container (docker --memory, a size-limited tmpfs on
# /overlay; see installer-tests.sh). Four test hooks of scripts/install.sh
# are used where the real event or hardware cannot exist in a container:
#   EV_TEST_NOW                         clock value (the container cannot
#                                       change the kernel clock)
#   EV_TEST_FAIL_DNSMASQ_INSTALL        dnsmasq-full installation fails
#   EV_TEST_SIGNAL_AFTER_DNSMASQ_REMOVE SIGTERM right after dnsmasq removal
#   EV_TEST_SYSROOT                     /proc and /sys files and the kernel
#                                       log of a router's flash (MTD/UBI)
#                                       layout, see make_sysroot
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
. /etc/openwrt_release
# an architecture / target / release that is not this router's (mismatch tests)
case "$(uname -m)" in x86_64) OTHER_ARCH=aarch64_cortex-a53 ;; *) OTHER_ARCH=x86_64 ;; esac
case "$DISTRIB_TARGET" in x86/64) OTHER_TARGET=mediatek/filogic ;; *) OTHER_TARGET=x86/64 ;; esac
case "$DISTRIB_RELEASE" in 24.10.0) OTHER_RELEASE=24.10.1 ;; *) OTHER_RELEASE=24.10.0 ;; esac
# installed packages that are not built for this architecture (or "all")
foreign_packages() {
	awk -v a="$DISTRIB_ARCH" '/^Package: /{ p = $2 } /^Architecture: /{ if ($2 != a && $2 != "all") printf " %s(%s)", p, $2 }' /usr/lib/opkg/status
}
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

	note "--check on a clean OpenWrt ${DISTRIB_RELEASE} (${DISTRIB_TARGET}, ${DISTRIB_ARCH})"
	expect_ok "--check passes" "check finished: no blocking problem found" --check --local "$DIST"
	grep -q "OpenWrt: ${DISTRIB_RELEASE} .*, target ${DISTRIB_TARGET}, architecture ${DISTRIB_ARCH}" "$LOG" && ok "--check detects release, target and architecture" || bad "release/target/architecture line"
	grep -q "kernel: $(uname -m) " "$LOG" && ok "--check reports the kernel architecture ($(uname -m))" || bad "kernel line missing"
	grep -qE "RAM: [0-9.]+ MB \((MemTotal|memory limit of the control group)\), required: 256 MB" "$LOG" && ok "--check reports RAM and the requirement" || bad "RAM line missing"
	grep -qE "flash/storage: [0-9.]+ MB \(disk\), required: 128 MB" "$LOG" && ok "--check reports the storage size" || bad "storage line missing"
	grep -qE "overlay: / \(overlay on overlay\), size [0-9.]+ MB, free [0-9.]+ MB" "$LOG" && ok "--check reports the overlay" || bad "overlay line missing"
	grep -q "package feeds: OpenWrt ${DISTRIB_RELEASE}, target ${DISTRIB_TARGET}, architecture ${DISTRIB_ARCH} - ok" "$LOG" && ok "--check accepts the feeds of this router" || bad "feed line missing"
	grep "packages from the feeds (${DISTRIB_ARCH}) to install:" "$LOG" | grep -q " sing-box-tiny" && ok "--check resolves sing-box-tiny from the ${DISTRIB_ARCH} feed" || bad "sing-box-tiny not in the dependency list"
	grep "packages from the feeds (${DISTRIB_ARCH}) to install:" "$LOG" | grep -q " dnsmasq-full" && ok "--check resolves dnsmasq-full and its dependencies" || bad "dnsmasq-full not in the dependency list"
	grep -qE "free space on /: [0-9.]+ MB, required: [0-9.]+ MB = [0-9]+ new packages .* margin: [0-9.]+ MB" "$LOG" && ok "--check reports required free space and margin" || bad "free space line missing"
	check "sing-box-tiny of the feed is built for ${DISTRIB_ARCH}" '[ "$(opkg info sing-box-tiny | sed -n "s/^Architecture: //p" | head -n1)" = "$DISTRIB_ARCH" ]'
	grep -q "system time: .* - ok" "$LOG" && ok "--check reports the system time" || bad "time line missing"
	grep -qE "HTTPS: https://downloads.openwrt.org/.*/Packages.sig - ok \(certificate verified\)" "$LOG" && ok "--check reports a working HTTPS request" || bad "HTTPS line missing"
	# regression (CI run of e5cd0184): the rootfs has /lib/libustream-ssl.so but
	# no /usr/lib/libustream-ssl.so*; HTTPS works and must be accepted
	check "HTTPS accepted although /usr/lib/libustream-ssl.so* does not exist" '! ls /usr/lib/libustream-ssl.so* >/dev/null 2>&1 && [ "$RC" = 0 ]'
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
	expect_fail "missing CA bundle detected before any download" "HTTPS does not work on this router: the TLS certificate of .* is not trusted" --check
	mv /tmp/certs.off/* /etc/ssl/certs/

	note "missing TLS library"
	mkdir -p /tmp/tls.off && mv /lib/libustream-ssl.so* /tmp/tls.off/
	expect_fail "missing TLS backend detected by a real HTTPS request" "HTTPS does not work on this router: wget \(uclient-fetch\) has no TLS backend" --check
	mv /tmp/tls.off/* /lib/

	# /etc/openwrt_release not matching the kernel (a copied or damaged file):
	# the real kernel and userland stay what they are, only the file is wrong
	note "wrong architecture in /etc/openwrt_release"
	cp /etc/openwrt_release /tmp/openwrt_release.orig
	sed -i "s/^DISTRIB_ARCH=.*/DISTRIB_ARCH='${OTHER_ARCH}'/" /etc/openwrt_release
	expect_fail "architecture mismatch detected" "architecture mismatch: /etc/openwrt_release says ${OTHER_ARCH}, the kernel runs on $(uname -m)" --check
	sed -i "s/^DISTRIB_ARCH=.*/DISTRIB_ARCH='sh4_generic'/" /etc/openwrt_release
	expect_fail "unknown/unsupported architecture refused" "architecture sh4_generic is not supported by this installer" --check
	cp /tmp/openwrt_release.orig /etc/openwrt_release

	note "package feeds of another architecture / target / release"
	cp /etc/opkg/distfeeds.conf /tmp/distfeeds.orig
	sed -i "s#/packages/${DISTRIB_ARCH}/packages#/packages/${OTHER_ARCH}/packages#" /etc/opkg/distfeeds.conf
	expect_fail "packages feed of another architecture refused" "openwrt_packages: architecture ${OTHER_ARCH}, this router is ${DISTRIB_ARCH}" --check --local "$DIST"
	cp /tmp/distfeeds.orig /etc/opkg/distfeeds.conf
	sed -i "s#/targets/${DISTRIB_TARGET}/#/targets/${OTHER_TARGET}/#" /etc/opkg/distfeeds.conf
	expect_fail "core/kmods feed of another target refused" "openwrt_core: target ${OTHER_TARGET}, this router is ${DISTRIB_TARGET}" --check --local "$DIST"
	cp /tmp/distfeeds.orig /etc/opkg/distfeeds.conf
	sed -i "s#/releases/${DISTRIB_RELEASE}/#/releases/${OTHER_RELEASE}/#" /etc/opkg/distfeeds.conf
	expect_fail "feeds of another release refused" "openwrt_base: release ${OTHER_RELEASE}, this router runs ${DISTRIB_RELEASE}" --check --local "$DIST"
	cp /tmp/distfeeds.orig /etc/opkg/distfeeds.conf

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
	expect_ok "failing optional feed only warns" "optional package feeds not available: openwrt_routing" --check --local "$DIST"
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
	check "the installed sing-box binary runs on this CPU ($(uname -m))" 'sing-box version | grep -q "^sing-box version 1\.1[2-9]"'
	check "every installed package is built for ${DISTRIB_ARCH} or all" '[ -z "$(foreign_packages)" ]'
	check "Easy VLESS packages are Architecture: all" '[ "$(opkg info easy-vless | sed -n "s/^Architecture: //p" | head -n1)" = all ]'
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
	hash -r 2>/dev/null; check "opkg removed" '[ ! -e /bin/opkg ]'
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

# ====================================================================== tlsboot
# Image without HTTPS backend and CA bundle (and without opkg): the base
# feed index, its signature and the packages are copied "from a PC" into
# one directory; install.sh verifies them with the router's keys, installs
# the TLS backend and CA bundle, bootstraps opkg and continues.
sc_tlsboot() {
	. /etc/openwrt_release
	base="https://downloads.openwrt.org/releases/${DISTRIB_RELEASE}/packages/${DISTRIB_ARCH}/base"
	pc=/tmp/pc
	mkdir -p "$pc" && cp "$DIST"/* "$pc/"
	wget -q -O "$pc/Packages" "$base/Packages" && wget -q -O "$pc/Packages.sig" "$base/Packages.sig"
	tlspkg="$(opkg list-installed | awk '$1 ~ /^libustream-/ { print $1; exit }')"
	check "TLS backend package present before the test ($tlspkg)" '[ -n "$tlspkg" ]'
	for p in "$tlspkg" ca-bundle opkg; do
		f="$(awk -v p="$p" '/^Package: /{ q = $2 } /^Filename: /{ if (q == p) print $2 }' "$pc/Packages")"
		wget -q -O "$pc/$f" "$base/$f"
		check "copied $f (as from a PC)" "[ -s '$pc/$f' ]"
	done
	tlsfile="$(ls "$pc"/"$tlspkg"_*.ipk)"

	note "image without TLS backend and CA bundle"
	opkg remove --force-depends "$tlspkg" ca-bundle >/dev/null 2>&1
	check "TLS backend and CA bundle removed" '[ -z "$(installed "$tlspkg")" ] && [ -z "$(installed ca-bundle)" ]'
	check "real wget: SSL support not available" 'wget -O /dev/null https://github.com/ 2>&1 | grep -q "SSL support not available"'
	expect_fail "no HTTPS and no files: clear instructions" "HTTPS does not work on this router: wget \(uclient-fetch\) has no TLS backend.*--local DIR" --check
	grep -q "base/Packages and Packages.sig" "$LOG" && ok "instructions name the index files" || bad "instructions incomplete"

	cp -r "$pc" /tmp/pc-bad && printf 'x' >>"/tmp/pc-bad/$(basename "$tlsfile")"
	expect_fail "modified TLS package refused" "checksum mismatch for $(basename "$tlsfile")" --local /tmp/pc-bad --replace-dnsmasq --yes --no-start
	cp -r "$pc" /tmp/pc-sig && printf '\nPackage: evtest\n' >>/tmp/pc-sig/Packages
	expect_fail "index with an invalid signature refused" "signature of /tmp/pc-sig/Packages is not valid" --local /tmp/pc-sig --replace-dnsmasq --yes --no-start
	expect_fail "--check with the files installs nothing" "--check: HTTPS does not work; the installer would install" --check --local "$pc"
	check "still no TLS backend after the refused runs" '[ -z "$(installed "$tlspkg")" ] && [ -z "$(installed ca-bundle)" ]'

	# regression (CI run of f158e5cb): with feed lists of an earlier
	# "opkg update" present, "opkg install /tmp/pc/ca-bundle_*.ipk" used the
	# feed entry of the same version and tried to download it over the HTTPS
	# that was still missing (circular dependency). The prerequisites must be
	# installed from the exact local files without any download attempt.
	tls_offline_run() { # tls_offline_run DESCRIPTION ARGS...
		local d="$1"; shift
		check "$d: feed lists of an earlier opkg update present" '[ -s /var/opkg-lists/openwrt_base ]'
		expect_ok "$d: installed from the local files, installation continues" \
			"HTTPS: .* - ok \(certificate verified\) after installing" "$@"
		grep -q "installing the HTTPS prerequisites from $pc .*ca-bundle" "$LOG" && ok "$d: ca-bundle taken from $pc" || bad "$d: ca-bundle not from $pc"
		if grep -qE "Downloading https://.*/(ca-bundle|libustream-)" "$LOG"; then bad "$d: opkg tried to download a TLS package"; show 30; else ok "$d: no download attempt for the TLS packages"; fi
		check "$d: TLS backend and CA bundle installed" '[ -n "$(installed "$tlspkg")" ] && [ -n "$(installed ca-bundle)" ]'
		check "$d: real wget HTTPS works again" 'wget -q -O /dev/null https://github.com/'
		check "$d: feed lists restored" '[ -s /var/opkg-lists/openwrt_base ]'
		check "$d: Easy VLESS $V installed" "[ \"\$(installed easy-vless)\" = \"$V\" ]"
	}

	note "no TLS backend / CA bundle, opkg present (normal flow with --local)"
	tls_offline_run "opkg present" --local "$pc" --replace-dnsmasq --yes --no-start

	note "no TLS backend / CA bundle and no opkg: --bootstrap-opkg from the verified local files"
	opkg remove --force-depends "$tlspkg" ca-bundle >/dev/null 2>&1
	opkg remove --force-removal-of-essential-packages opkg >/dev/null 2>&1; rm -f /bin/opkg
	hash -r 2>/dev/null
	check "opkg, TLS backend and CA bundle removed again" '[ ! -e /bin/opkg ] && wget -O /dev/null https://github.com/ 2>&1 | grep -q "SSL support not available"'
	tls_offline_run "bootstrap" --bootstrap-opkg --local "$pc" --replace-dnsmasq --yes --no-start
	grep -q "opkg .* installed from $pc/" "$LOG" && ok "opkg bootstrapped from the local verified index" || bad "opkg not bootstrapped locally"
	check "opkg registered in the database after HTTPS works" '[ -n "$(installed opkg)" ]'
	no_leftovers "tlsboot"
}

# ====================================================================== upgrade
# Upgrade chain through the published releases (real GitHub releases, their
# own installers): 0.5.1-r1 -> 0.5.1-r2 -> this build; then uninstall and
# reinstall.
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

	note "upgrade to the published 0.5.1-r2 with its own installer"
	wget -q -O /tmp/install-051r2.sh https://github.com/quargelk/easy-vless/releases/download/v0.5.1-r2/install.sh
	check "v0.5.1-r2 installer downloaded from GitHub over HTTPS" '[ -s /tmp/install-051r2.sh ] && grep -q "EV_VERSION=\"0.5.1-r2\"" /tmp/install-051r2.sh'
	sh /tmp/install-051r2.sh --no-start >"$LOG" 2>&1; RC=$?
	[ "$RC" = 0 ] && grep -q "installed now: 0.5.1-r1" "$LOG" && ok "0.5.1-r1 -> 0.5.1-r2 with the published installer" || { bad "0.5.1-r2 upgrade (rc=$RC)"; show 30; }
	check "easy-vless 0.5.1-r2 installed" '[ "$(installed easy-vless)" = "0.5.1-r2" ]'
	uci export easy_vless >/tmp/cfg-r2
	cmp -s /tmp/cfg-before /tmp/cfg-r2 && ok "configuration unchanged by 0.5.1-r1 -> 0.5.1-r2" || { bad "configuration changed by 0.5.1-r2"; diff /tmp/cfg-before /tmp/cfg-r2 | head -20; }

	note "upgrade to $V"
	expect_ok "upgrade 0.5.1-r2 -> $V" "installed now: 0.5.1-r2" --local "$DIST" --no-start
	grep -qE "free space on /: .*margin" "$LOG" && ok "upgrade checks the free space" || bad "no free space check on upgrade"
	for p in easy-vless easy-vless-sing-box luci-app-easy-vless; do
		check "$p upgraded to $V" "[ \"\$(installed $p)\" = \"$V\" ]"
	done
	uci export easy_vless >/tmp/cfg-after
	if cmp -s /tmp/cfg-before /tmp/cfg-after; then ok "configuration (nodes, subscription, HAPP, HWID flag) unchanged by the upgrades"
	else bad "configuration changed by the upgrade"; diff /tmp/cfg-before /tmp/cfg-after | head -20; fi
	check "HWID unchanged" "[ \"\$(cat /etc/easy_vless/hwid)\" = \"$hwid_before\" ]"
	check "prepared resources match tests/resources.sha256" \
		"grep '  root/' '$W/tests/resources.sha256' | sed 's#  root/#  /#' | sha256sum -c - >/dev/null"
	check "service still enabled" '/etc/init.d/easy_vless enabled'
	check "every installed package is built for ${DISTRIB_ARCH} or all" '[ -z "$(foreign_packages)" ]'

	note "uninstall and reinstall"
	opkg remove luci-app-easy-vless easy-vless-sing-box easy-vless >"$LOG" 2>&1
	check "packages removed" '[ -z "$(installed easy-vless)" ] && [ ! -e /etc/init.d/easy_vless ]'
	check "fw4 include removed on uninstall" '! uci -q get firewall.easy_vless >/dev/null'
	check "no Easy VLESS nft table left" '! nft list table inet easy_vless >/dev/null 2>&1'
	expect_ok "reinstall after uninstall" "Easy VLESS packages verified" --local "$DIST" --no-start
	check "fw4 include back after reinstall" '[ "$(uci -q get firewall.easy_vless)" = include ]'
	check "easy-vless $V installed again" "[ \"\$(installed easy-vless)\" = \"$V\" ]"
	check "configuration kept across uninstall/reinstall" "[ \"\$(uci export easy_vless | md5sum)\" = \"\$(md5sum </tmp/cfg-after)\" ]"
}

# ====================================================================== system requirements
# make_sysroot NAME DIR: /proc, /sys and kernel log files of a router's flash
# and memory layout for EV_TEST_SYSROOT. Values from the OpenWrt 24.10.3
# device trees and the kernel's own formats:
#   tr3000       Cudy TR3000 v1 (mt7981b-cudy-tr3000-v1.dts): 128 MiB
#                SPI-NAND, partitions BL2..FIP, "ubi" 0x5c0000 + 64 MiB;
#                UBI reserves 20 eraseblocks for bad blocks (20 per 1024 of
#                the 128 MiB chip); overlay = UBIFS rootfs_data; the boot
#                messages have left the kernel log (long uptime)
#   tr3000-log   the same, boot message of the SPI-NAND driver still present
#   tr3000-nobeb the same without UBI and kernel log information: only the
#                partition layout (lower bound 69.75 MiB) is known
#   nand64       64 MiB NAND router, UBIFS overlay
#   nor16        16 MiB SPI-NOR router, JFFS2 overlay
#   ram128       128 MB RAM router (MemTotal 119 MB)
#   ram256       256 MB RAM router (MemTotal 230 MB)
#   disk120      x86 image written 1:1 to a disk (120.5 MiB), ext4 root
#   disk1g       x86 with a 1 GiB disk
make_sysroot() {
	local n="$1" d="$2" mem=482000
	rm -rf "$d"; mkdir -p "$d/proc" "$d/sys/class/mtd" "$d/sys/class/ubi" "$d/sys/block" /overlay
	mtd() { # mtd N NAME SIZE OFFSET ERASESIZE
		mkdir -p "$d/sys/class/mtd/mtd$1"
		echo "$2" >"$d/sys/class/mtd/mtd$1/name"; echo "$3" >"$d/sys/class/mtd/mtd$1/size"
		echo "$4" >"$d/sys/class/mtd/mtd$1/offset"; echo "$5" >"$d/sys/class/mtd/mtd$1/erasesize"
		printf 'mtd%s: %08x %08x "%s"\n' "$1" "$3" "$5" "$2" >>"$d/proc/mtd"
	}
	ubi() { # ubi MTDNUM RESERVED_FOR_BAD BAD_PEB_COUNT
		mkdir -p "$d/sys/class/ubi/ubi0"
		echo "$1" >"$d/sys/class/ubi/ubi0/mtd_num"; echo "$2" >"$d/sys/class/ubi/ubi0/reserved_for_bad"
		echo "$3" >"$d/sys/class/ubi/ubi0/bad_peb_count"
	}
	ubifs_mounts() {
		printf '/dev/root /rom squashfs ro,relatime,errors=continue 0 0\n/dev/ubi0_2 /overlay ubifs rw,noatime,assert=read-only,ubi=0,vol=2 0 0\noverlayfs:/overlay / overlay rw,noatime,lowerdir=/,upperdir=/overlay/upper,workdir=/overlay/work,xino=off 0 0\ntmpfs /tmp tmpfs rw,nosuid,nodev,noatime 0 0\n' >"$d/proc/mounts"
	}
	tr3000_mtd() {
		echo "dev:    size   erasesize  name" >"$d/proc/mtd"
		mtd 0 BL2 1048576 0 131072; mtd 1 u-boot-env 524288 1048576 131072
		mtd 2 Factory 2097152 1572864 131072; mtd 3 bdinfo 262144 3670016 131072
		mtd 4 FIP 2097152 3932160 131072; mtd 5 ubi 67108864 6029312 131072
	}
	case "$n" in
		tr3000) tr3000_mtd; ubi 5 20 0; ubifs_mounts ;;
		tr3000-log) tr3000_mtd; ubi 5 20 0; ubifs_mounts
			echo "[    1.234567] spi-nand spi0.0: 128 MiB, block size: 128 KiB, page size: 2048, OOB size: 64" >"$d/dmesg.txt" ;;
		tr3000-nobeb) tr3000_mtd; ubifs_mounts ;;
		nand64) echo "dev:    size   erasesize  name" >"$d/proc/mtd"
			mtd 0 u-boot 1048576 0 131072; mtd 1 ubi 66060288 1048576 131072
			ubi 1 10 0; ubifs_mounts
			echo "[    0.912345] nand: 64 MiB, SLC, erase size: 128 KiB, page size: 2048, OOB size: 64" >"$d/dmesg.txt" ;;
		nor16) echo "dev:    size   erasesize  name" >"$d/proc/mtd"
			mtd 0 u-boot 196608 0 65536; mtd 1 firmware 16515072 196608 65536
			mtd 2 rootfs_data 8388608 8323072 65536
			printf '/dev/root /rom squashfs ro,relatime 0 0\n/dev/mtdblock2 /overlay jffs2 rw,noatime 0 0\noverlayfs:/overlay / overlay rw,noatime 0 0\n' >"$d/proc/mounts"
			echo "[    0.523456] spi-nor spi0.0: w25q128 (16384 Kbytes)" >"$d/dmesg.txt" ;;
		ram128|ram256) tr3000_mtd; ubi 5 20 0; ubifs_mounts
			[ "$n" = ram128 ] && mem=121856 || mem=236032 ;;
		disk120|disk1g)
			printf '/dev/root / ext4 rw,noatime 0 0\ntmpfs /tmp tmpfs rw,nosuid,nodev,noatime 0 0\n' >"$d/proc/mounts"
			mkdir -p "$d/sys/block/sda/sda1" "$d/sys/block/sda/sda2" "$d/sys/block/loop0"
			[ "$n" = disk120 ] && echo 246784 >"$d/sys/block/sda/size" || echo 2097152 >"$d/sys/block/sda/size"
			echo 8388608 >"$d/sys/block/loop0/size" ;;
	esac
	printf 'MemTotal:         %s kB\nMemFree:          %s kB\n' "$mem" "$((mem / 2))" >"$d/proc/meminfo"
}
# with_sysroot NAME COMMAND...: COMMAND with the hardware layout NAME
with_sysroot() { local n="$1"; shift; make_sysroot "$n" "/tmp/sysroot-$n"; EV_TEST_SYSROOT="/tmp/sysroot-$n" "$@"; }

# Hardware layouts (EV_TEST_SYSROOT) - every refused case changes nothing.
sc_sysreq() {
	A="--check --local $DIST"
	note "flash size"
	# shellcheck disable=SC2086
	with_sysroot tr3000 expect_ok "TR3000 v1 (128 MiB SPI-NAND, 64 MiB UBI) accepted" "check finished: no blocking problem found" $A
	grep -q "flash/storage: 128.0 MB (flash chip (UBI bad-block reserve)), required: 128 MB" "$LOG" && ok "TR3000 v1: chip size 128 MB derived from the UBI bad-block reserve" || { bad "TR3000 v1 flash line"; show; }
	grep -q "overlay: /overlay (ubifs on /dev/ubi0_2)" "$LOG" && ok "TR3000 v1: UBIFS overlay detected" || bad "TR3000 v1 overlay line"
	grep -q "ubifs compresses: 75% of the uncompressed" "$LOG" && ok "TR3000 v1: UBIFS compression taken into account" || bad "compression note missing"
	# shellcheck disable=SC2086
	with_sysroot tr3000-log expect_ok "TR3000 v1 with the boot log accepted" "flash/storage: 128.0 MB \\(flash chip \\(kernel log\\)\\)" $A
	# shellcheck disable=SC2086
	with_sysroot tr3000-nobeb expect_ok "only the partition layout known: warning, free space decides" "flash size: at least 69.8 MB \\(MTD partition layout \\(lower bound\\)" $A
	grep -q "check finished: no blocking problem found" "$LOG" && ok "lower bound alone does not refuse the router" || bad "lower bound refused"
	# shellcheck disable=SC2086
	with_sysroot nand64 expect_fail "64 MB NAND refused" "flash/storage too small: 64.0 MB \\(flash chip \\(kernel log\\)\\), required: at least 128 MB. Nothing was changed" $A
	# shellcheck disable=SC2086
	with_sysroot nor16 expect_fail "16 MB NOR (JFFS2) refused" "flash/storage too small: 16.0 MB \\(flash chip \\(kernel log\\)\\), required: at least 128 MB" $A
	# shellcheck disable=SC2086
	with_sysroot disk120 expect_fail "x86 image on a 120.5 MiB disk refused" "flash/storage too small: 120.5 MB \\(disk\\), required: at least 128 MB" $A
	# shellcheck disable=SC2086
	with_sysroot disk1g expect_ok "x86 with a 1 GiB disk accepted" "flash/storage: 1024.0 MB \\(disk\\), required: 128 MB" $A

	note "RAM"
	# shellcheck disable=SC2086
	with_sysroot ram128 expect_fail "128 MB RAM router refused" "not enough RAM: 119.0 MB \\(MemTotal\\), required: 256 MB installed RAM.*Nothing was changed" $A
	# shellcheck disable=SC2086
	with_sysroot ram256 expect_ok "256 MB RAM router (MemTotal 230.5 MB) accepted" "RAM: 230.5 MB \\(MemTotal\\), required: 256 MB" $A

	nothing_installed "after the system requirement checks"
	no_leftovers "sysreq"
}

# Real limit of the container: docker --memory 128m
sc_ram128() {
	expect_fail "128 MB memory limit refused before any change" "not enough RAM: 128.0 MB \\(memory limit of the control group\\), required: 256 MB" \
		--local "$DIST" --replace-dnsmasq --yes --no-start
	nothing_installed "RAM 128 MB"
	no_leftovers "ram128"
}

# Real limit of the container: docker --memory 256m - full installation
sc_ram256() {
	expect_ok "256 MB memory limit: installation succeeds" "Easy VLESS packages verified against SHA256SUMS" \
		--local "$DIST" --replace-dnsmasq --yes --no-start
	grep -qE "RAM: 256.0 MB \\(memory limit of the control group\\), required: 256 MB" "$LOG" && ok "RAM limit of the container detected (256 MB)" || { bad "RAM line"; show; }
	check "Easy VLESS $V installed with 256 MB" "[ \"\$(installed easy-vless)\" = \"$V\" ]"
}

# Real free space: /overlay is a 16 MB tmpfs (docker --tmpfs)
sc_smallspace() {
	expect_fail "16 MB free on /overlay refused before any change" "not enough free space on /overlay: 1[56]\\.[0-9] MB free, [0-9.]+ MB required \\(missing [0-9.]+ MB\\). Nothing was changed" \
		--local "$DIST" --replace-dnsmasq --yes --no-start
	grep -q "overlay: /overlay (tmpfs on tmpfs)" "$LOG" && ok "the size-limited /overlay is measured" || bad "overlay line"
	nothing_installed "16 MB overlay"
	no_leftovers "smallspace"
}

# TR3000 v1: flash layout of the device tree, /overlay a 40 MB tmpfs (free
# space of a fresh TR3000 v1 with the default image), LuCI installed like in
# the release image. A fresh installation must pass and show the margin.
sc_tr3000() {
	opkg install luci >/tmp/luci.log 2>&1 || { tail -n 20 /tmp/luci.log; bad "cannot install luci"; return; }
	make_sysroot tr3000 /tmp/sysroot-tr3000
	EV_TEST_SYSROOT=/tmp/sysroot-tr3000 expect_ok "TR3000 v1 layout with 40 MB free: fresh installation succeeds" "Easy VLESS packages verified against SHA256SUMS" \
		--local "$DIST" --replace-dnsmasq --yes --no-start
	grep -q "flash/storage: 128.0 MB (flash chip (UBI bad-block reserve))" "$LOG" && ok "TR3000 v1: 128 MB flash" || bad "flash line"
	line="$(grep "free space on /overlay:" "$LOG")"
	echo "    | $line"
	echo "$line" | grep -qE "free space on /overlay: (39|40)\\.[0-9] MB, required: [0-9.]+ MB .*margin: [0-9.]+ MB" && ok "TR3000 v1: required space and margin shown" || bad "free space line"
	req="$(echo "$line" | sed -n 's/.*required: \([0-9]*\)\..*/\1/p')"
	check "TR3000 v1: worst case below 40 MB (${req} MB)" "[ -n '$req' ] && [ '$req' -lt 40 ]"
	check "Easy VLESS $V installed" "[ \"\$(installed easy-vless)\" = \"$V\" ]"
	EV_TEST_SYSROOT=/tmp/sysroot-tr3000 expect_ok "TR3000 v1: repeated run (upgrade path) passes" "installed now: $V" --local "$DIST" --no-start
}

case "${1:-}" in
	preflight|online|rollback|bootstrap|tlsboot|upgrade|sysreq|ram128|ram256|smallspace|tr3000) ;;
	*) echo "usage: $0 preflight|online|rollback|bootstrap|tlsboot|upgrade|sysreq|ram128|ram256|smallspace|tr3000"; exit 2 ;;
esac
echo "===== scenario $1 (Easy VLESS $V, OpenWrt ${DISTRIB_RELEASE} ${DISTRIB_TARGET} ${DISTRIB_ARCH}, kernel $(uname -m)) ====="
prepare
"sc_$1"
echo "===== $1: PASS: $PASS  FAIL: $FAIL ====="
[ "$FAIL" -eq 0 ]
