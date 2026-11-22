#!/bin/ash
# Tests the service and its own rules in a disposable network namespace.
set -eu
APP=/usr/share/easy_vless/app.sh
INIT=/etc/init.d/easy_vless

assert_field() {
	actual=$(jsonfilter -s "$("$APP" status)" -e "@.$1")
	[ "$actual" = "$2" ] || { echo "Expected $1=$2, got $actual" >&2; exit 1; }
}
trap '"$INIT" stop >/dev/null 2>&1 || :' EXIT
if nft list table inet easy_vless >/dev/null 2>&1; then
	echo "Namespace already contains Easy VLESS rules" >&2
	exit 1
fi
# This table is unrelated to Easy VLESS and must survive start and stop.
nft add table inet ev_test_unrelated
uci -q set easy_vless.global.node=fixture
uci -q set easy_vless.global.enabled=1
uci -q set easy_vless.global.client_proxy=0
uci -q set easy_vless.global.localhost_proxy=0
uci -q set easy_vless.@global_forwarding[0].ipv6_tproxy=0
for mode in redirect tproxy; do
	uci -q set "easy_vless.@global_forwarding[0].tcp_proxy_way=$mode"
	uci -q commit easy_vless
	if ! "$INIT" restart; then
		tail -n 50 /tmp/log/easy_vless.log >&2
		exit 1
	fi
	assert_field running true
	assert_field state running
	assert_field nft_table true
	pid=$(cat /var/run/easy_vless.pid)
	kill -0 "$pid"
	nft list table inet ev_test_unrelated >/dev/null
	ip rule show | grep -q 'fwmark 0x45560000.*lookup 998'
	echo "PASS service start in $mode"

	uci -q set easy_vless.fixture.transport=xhttp
	uci -q set easy_vless.fixture.xhttp_mode=invalid
	uci -q commit easy_vless
	if "$INIT" restart; then
		echo "Invalid config replaced a running service" >&2
		exit 1
	fi
	[ "$(cat /var/run/easy_vless.pid)" = "$pid" ]
	assert_field running true
	echo "PASS invalid configuration leaves the running instance intact"

	uci -q set easy_vless.fixture.transport=tcp
	uci -q delete easy_vless.fixture.xhttp_mode
	uci -q commit easy_vless
	"$INIT" stop
	assert_field running false
	assert_field nft_table false
	nft list table inet ev_test_unrelated >/dev/null
	! ip rule show | grep -q 'fwmark 0x45560000.*lookup 998'
	echo "PASS service stop cleans Easy VLESS rules in $mode"
done
uci -q set easy_vless.global.enabled=0
uci -q commit easy_vless
nft delete table inet ev_test_unrelated
