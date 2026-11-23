#!/bin/ash
# Run in a disposable OpenWrt image with system dependencies already installed
# and no Easy VLESS. Use the actual release bundle, including PACKAGES.sha256.
set -eu
bundle=${1:?provide the signed RC bundle on a disposable OpenWrt test image}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

snapshot() {
	if command -v apk >/dev/null 2>&1; then
		apk --network=no --repositories-file /dev/null info -v | LC_ALL=C sort
	else
		opkg list-installed | LC_ALL=C sort
	fi
}
snapshot > "$fixture/baseline"
test ! -e /etc/config/easy_vless
sha256sum /etc/config/firewall > "$fixture/firewall.sha256"
! grep -Eq '^(easy-vless|sing-box-lx)[ -]' "$fixture/baseline"
cp -R "$bundle" "$fixture/bad"
printf '\n' >> "$fixture/bad/PACKAGES.sha256"
if sh "$fixture/bad/install.sh" --check --local "$fixture/bad" --offline > "$fixture/bad.log" 2>&1; then exit 1; fi
grep -F 'release manifest digest mismatch' "$fixture/bad.log"

sh "$bundle/install.sh" --check --local "$bundle" --offline
snapshot > "$fixture/checked"
cmp "$fixture/baseline" "$fixture/checked"
if EV_TEST_FAIL_EV_INSTALL=1 sh "$bundle/install.sh" --local "$bundle" --offline --no-start; then exit 1; fi
snapshot > "$fixture/rolled-back"
cmp "$fixture/baseline" "$fixture/rolled-back"
test ! -e /etc/config/easy_vless
sha256sum -c "$fixture/firewall.sha256"
echo "PASS rollback after partial install"

if EV_TEST_KILL_AFTER_INSTALL=1 sh "$bundle/install.sh" --local "$bundle" --offline --no-start; then exit 1; fi
for delay in 1 1 1 1 1 1 1 1 1 1; do
	snapshot > "$fixture/watchdog"
	if cmp -s "$fixture/baseline" "$fixture/watchdog" &&
		flock -xn /var/lock/easy_vless_install.lock true; then break; fi
	sleep "$delay"
done
cmp "$fixture/baseline" "$fixture/watchdog"
test ! -e /etc/config/easy_vless
sha256sum -c "$fixture/firewall.sha256"
echo "PASS detached rollback after SIGKILL"

sh "$bundle/install.sh" --local "$bundle" --offline --no-start
sing-box-lx version | grep -F 'sing-box version 1.14.4-lx.35'
test -s /etc/config/easy_vless
echo "PASS authenticated fresh installation"
