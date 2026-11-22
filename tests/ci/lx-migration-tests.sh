#!/bin/ash
# Run in a disposable OpenWrt container with the current packages installed.
set -eu
new=${DIST:-/bundle}
old=${EV_OLD_BUNDLE:-/old}
config=/etc/config/easy_vless
args="--offline --no-start --rollback-dir $old --local $new"

retry() {
	local n=1
	until "$@"; do
		[ "$n" -lt 4 ] || return 1
		n=$((n + 1))
		sleep 2
	done
}

if command -v apk >/dev/null 2>&1; then
	args="$args --allow-unsigned"
	retry apk update
	retry apk add --cache-predownload sing-box-tiny
	apk add --network=no --repositories-file /dev/null --allow-untrusted \
		"$old/easy-vless-1.2.0-r1.apk" "$old/easy-vless-sing-box-1.2.0-r1.apk" "$old/luci-app-easy-vless-1.2.0-r1.apk"
	apk del --network=no sing-box-lx
	version() {
		apk query --installed --fields name,version "$1" | awk -v p="$1" '$1 == "Name:" { n = $2 } $1 == "Version:" && n == p { print $2 }'
	}
else
	retry opkg update
	retry opkg install sing-box-tiny
	opkg install --force-downgrade "$old"/*_all.ipk
	opkg remove sing-box-lx
	version() { opkg list-installed | awk -v p="$1" '$1 == p { print $3 }'; }
fi

[ "$(version easy-vless)" = 1.2.0-r1 ]
[ "$(version easy-vless-sing-box)" = 1.2.0-r1 ]
[ "$(version luci-app-easy-vless)" = 1.2.0-r1 ]
[ ! -e /usr/bin/sing-box-lx ]
old_core=$(sha256sum /usr/bin/sing-box)
uci -q batch <<UCI
set easy_vless.global.remote_fakedns=1
set easy_vless.fixture=nodes
set easy_vless.fixture.type=sing-box
set easy_vless.fixture.protocol=vless
set easy_vless.fixture.remarks='Migration fixture'
set easy_vless.fixture.address=192.0.2.1
set easy_vless.fixture.port=443
set easy_vless.fixture.uuid=00000000-0000-4000-8000-000000000001
set easy_vless.global.node=fixture
commit easy_vless
UCI
cp "$config" /tmp/ev-migration.uci

if EV_TEST_FAIL_EV_INSTALL=1 sh "$new/install.sh" $args; then
	echo "fault injection did not report failure" >&2
	exit 1
fi
[ "$(version easy-vless)" = 1.2.0-r1 ]
[ "$(version easy-vless-sing-box)" = 1.2.0-r1 ]
[ "$(version luci-app-easy-vless)" = 1.2.0-r1 ]
[ ! -e /usr/bin/sing-box-lx ]
cmp "$config" /tmp/ev-migration.uci
[ "$(sha256sum /usr/bin/sing-box)" = "$old_core" ]
echo "PASS real rollback to Easy VLESS 1.2.0"

sh "$new/install.sh" $args
[ "$(version easy-vless)" = 1.3.0-r1 ]
[ "$(version sing-box-lx)" = 1.14.4_p35-r1 ]
[ "$(sha256sum /usr/bin/sing-box)" = "$old_core" ]
cmp "$config" /tmp/ev-migration.uci
echo "PASS migration from Easy VLESS 1.2.0 with sing-box-tiny"
