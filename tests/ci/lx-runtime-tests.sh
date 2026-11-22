#!/bin/ash
# Run only in a disposable OpenWrt rootfs. The containers share the host
# kernel, so this exercises packages, UCI, rpcd and core configs.
set -eu
W=${W:-/w}
DIST=${DIST:-$W/dist}
APP=/usr/share/easy_vless/app.sh
CONFIG=/etc/config/easy_vless
mkdir -p /var/lock /var/run
retry() {
	local attempt=1
	until "$@"; do
		[ "$attempt" -lt 4 ] || return 1
		attempt=$((attempt + 1))
		sleep 2
	done
}

unsigned=
if [ "${EV_CI_CHANNEL:-ipk}" = apk ]; then
	retry apk update
	retry apk add --cache-predownload firewall4 dnsmasq-full rpcd
	unsigned=--allow-unsigned
else
	retry opkg update
	opkg remove dnsmasq
	retry opkg install firewall4 dnsmasq-full rpcd
fi

retry sh "$W/scripts/install.sh" --check --local "$DIST" $unsigned
retry sh "$W/scripts/install.sh" --local "$DIST" $unsigned --no-start

SKIP_INSTALL=1 W="$W" DIST="$DIST" sh "$W/tests/ci/openwrt-runtime-tests.sh"
status=$(ubus call luci.easy_vless status)
[ "$(jsonfilter -s "$status" -e '@.api_version')" = 1 ]
[ "$(jsonfilter -s "$status" -e '@.core.compatible')" = true ]
[ "$(jsonfilter -s "$status" -e '@.core.version')" = "1.14.4-lx.35" ]

id=00000000-0000-4000-8000-000000000001
pub=$(sing-box-lx generate reality-keypair | sed -n 's/^PublicKey: //p')
test -n "$pub"
uci -q batch <<UCI
set easy_vless.fixture=nodes
set easy_vless.fixture.type=sing-box
set easy_vless.fixture.protocol=vless
set easy_vless.fixture.remarks=Fixture
set easy_vless.fixture.address=127.0.0.1
set easy_vless.fixture.port=443
set easy_vless.fixture.uuid=$id
set easy_vless.fixture.tls=1
set easy_vless.fixture.tls_serverName=localhost
set easy_vless.fixture.utls=1
set easy_vless.fixture.fingerprint=chrome
set easy_vless.fixture.reality=1
set easy_vless.fixture.reality_publicKey=$pub
set easy_vless.fixture.reality_shortId=0123456789abcdef
set easy_vless.fixture.flow=xtls-rprx-vision
set easy_vless.fixture.transport=tcp
set easy_vless.global.node=fixture
commit easy_vless
UCI
check_node() {
	if ! "$APP" check fixture; then
		# The fixture contains only test data.
		cat /tmp/etc/easy_vless_check/config.json.check.log 2>/dev/null || :
		exit 1
	fi
}
check_node
uci -q delete easy_vless.fixture.flow
uci -q delete easy_vless.fixture.reality
for transport in ws grpc httpupgrade xhttp; do
	uci -q set "easy_vless.fixture.transport=$transport"
	uci -q commit easy_vless
	check_node
done
uci -q set easy_vless.fixture.xhttp_mode=invalid
uci -q commit easy_vless
if "$APP" check fixture; then
	echo "invalid XHTTP mode was accepted" >&2
	exit 1
fi
uci -q delete easy_vless.fixture.xhttp_mode
uci -q set easy_vless.fixture.protocol=trojan
uci -q set "easy_vless.fixture.password=$id"
uci -q set easy_vless.fixture.transport=tcp
uci -q set easy_vless.global.remote_fakedns=1
uci -q commit easy_vless
check_node
uci -q set easy_vless.@global_forwarding[0].tcp_proxy_way=tproxy
uci -q set easy_vless.@global_forwarding[0].ipv6_tproxy=1
uci -q commit easy_vless
check_node

uci -q batch <<UCI
set easy_vless.fixture_group=nodes
set easy_vless.fixture_group.type=sing-box
set easy_vless.fixture_group.protocol=_urltest
set easy_vless.fixture_group.remarks=Group
add_list easy_vless.fixture_group.urltest_node=fixture
commit easy_vless
UCI
"$APP" check fixture_group

# Exercise process readiness and cleanup through the production helper with a
# local SOCKS5 listener. Network transfer is covered separately.
cfg=/tmp/etc/easy_vless/runtime_fixture.json
port=49192
NO_REC_PROCESS=1 "$APP" run_socks flag=runtime_fixture node=fixture \
	bind=127.0.0.1 socks_port=$port config_file="$cfg"
pid="$(cat "$cfg.pid")"
kill -0 "$pid"
kill "$pid"
for i in 1 2 3 4 5; do
	grep -aFq "$cfg" "/proc/$pid/cmdline" 2>/dev/null || break
	sleep 1
done
! grep -aFq "$cfg" "/proc/$pid/cmdline" 2>/dev/null
rm -f "$cfg" "$cfg.pid" "$cfg.check.log"

if [ "${EV_CI_NET_ADMIN:-0}" = 1 ]; then
	sh "$W/tests/ci/lx-service-tests.sh"
fi

if [ -n "${EV_OLD_BUNDLE:-}" ]; then
	sh "$W/tests/ci/lx-migration-tests.sh"
fi

cp "$CONFIG" /tmp/ev-before.uci
sh "$W/scripts/install.sh" --check --local "$DIST" $unsigned --offline
sh "$W/scripts/install.sh" --local "$DIST" $unsigned --offline --no-start
cmp "$CONFIG" /tmp/ev-before.uci
if [ "${EV_CI_CHANNEL:-ipk}" = apk ]; then
	apk del luci-app-easy-vless easy-vless-sing-box easy-vless sing-box-lx
else
	opkg remove luci-app-easy-vless easy-vless-sing-box easy-vless sing-box-lx
fi
test ! -e /usr/bin/sing-box-lx
dnsmasq --version | grep -qw nftset
echo "PASS packages, rpcd, generated configurations, offline reinstall and removal"
