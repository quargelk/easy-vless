#!/bin/sh
# Offline rollback for the fresh-install trial. The watchdog verifies
# recovery.sha256 before calling this script from the recovery directory.
set -eu
umask 077
offline_apk() {
	apk --network=no --repositories-file /dev/null --logfile=no "$@"
}
packages() {
	offline_apk info -v > current.packages.unsorted || return 1
	LC_ALL=C sort current.packages.unsorted
}
. /etc/openwrt_release
[ "$DISTRIB_TARGET" = mediatek/filogic ]
[ "$DISTRIB_ARCH" = aarch64_cortex-a53 ]
[ "$DISTRIB_RELEASE" = 25.12.6 ]
old=$(sed -n 's/^dnsmasq-\([0-9].*\)$/\1/p' baseline.packages)
[ "$old" = 2.93-r1 ]
! grep -Eq '^(dnsmasq-full|easy-vless|luci-app-easy-vless|sing-box-lx)-' baseline.packages
apk --logfile=no verify ./dnsmasq-rollback/packages.adb
tar -tzf baseline.config.tar.gz > baseline.config.files
grep -qx 'etc/config/dhcp' baseline.config.files

if [ -x /etc/init.d/easy_vless ]; then
	/etc/init.d/easy_vless stop
fi
set --
for pkg in luci-app-easy-vless easy-vless-sing-box easy-vless sing-box-lx dnsmasq-full; do
	if offline_apk info --exists "$pkg" >/dev/null; then set -- "$@" "$pkg"; fi
done
[ "$#" -eq 0 ] || offline_apk del "$@"
packages > restored.packages
if ! grep -qx "dnsmasq-$old" restored.packages; then
	offline_apk --repository ./dnsmasq-rollback/packages.adb add "dnsmasq=$old"
fi
packages > restored.packages
cmp baseline.packages restored.packages
cp -p baseline.world /etc/apk/world
tar -xzf baseline.config.tar.gz -C /
if ! grep -qx 'etc/config/easy_vless' baseline.config.files; then
	rm -f /etc/config/easy_vless
fi
/etc/init.d/firewall reload
/etc/init.d/dnsmasq restart
for delay in 1 2 3 4 5; do
	if /etc/init.d/dnsmasq running && nslookup localhost 127.0.0.1 >/dev/null; then
		cmp baseline.world /etc/apk/world
		exit 0
	fi
	sleep "$delay"
done
exit 1
