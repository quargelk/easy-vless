#!/bin/bash
# Easy VLESS - checks of the built .apk packages (OpenWrt 25.12, apk v3),
# the counterpart of the .ipk checks in the build job:
#   bash tests/apk-package-check.sh <dir with the .apk files> <apk binary>
# <apk binary>: apk-tools 3 of the SDK (staging_dir/host/bin/apk). Checks per
# package: apk v3 format, name, version (Makefile), arch noarch, the exact
# dependencies, maintainer scripts, the files (extracted with "apk extract"),
# their modes, the prepared resources and the compiled translation.

set -uo pipefail
DIR="$(cd "${1:?usage: $0 <dir> <apk binary>}" && pwd)"
APK="${2:?usage: $0 <dir> <apk binary>}"
W="$(cd "$(dirname "$0")/.." && pwd)"
V="$(sed -n 's/^PKG_VERSION:=//p' "$W/Makefile")-r$(sed -n 's/^PKG_RELEASE:=//p' "$W/Makefile")"
T="$(mktemp -d)"; trap 'rm -rf "${T:?}"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

info()    { "$APK" adbdump "$1" 2>/dev/null | sed -n "s/^  $2: //p" | head -n1; }
depends() { "$APK" adbdump "$1" 2>/dev/null | sed -n '/^  depends:/,/^ \{0,2\}[a-z]/s/^    - //p' | sort | tr '\n' ' ' | sed 's/ $//'; }
scripts() { "$APK" adbdump "$1" 2>/dev/null | sed -n '/^scripts:/,/^[a-z]/s/^  \([a-z-]*\): |$/\1/p' | sort | tr '\n' ' ' | sed 's/ $//'; }

# check_pkg NAME "EXPECTED DEPENDS (sorted)" "EXPECTED SCRIPTS (sorted)"
check_pkg() {
	local p="$1" f="$DIR/$1-$V.apk" d
	echo "== $p"
	[ -s "$f" ] || { bad "$p: $f missing"; return 1; }
	[ "$(head -c 3 "$f")" = "ADB" ] && ok "$p: apk v3 (ADB) file" || bad "$p: not an apk v3 file"
	[ "$(info "$f" name)" = "$p" ] && ok "$p: name" || bad "$p: name is '$(info "$f" name)'"
	[ "$(info "$f" version)" = "$V" ] && ok "$p: version $V" || bad "$p: version is '$(info "$f" version)', Makefile says $V"
	[ "$(info "$f" arch)" = noarch ] && ok "$p: arch noarch" || bad "$p: arch is '$(info "$f" arch)'"
	[ "$(info "$f" license)" = GPL-3.0-only ] && ok "$p: license" || bad "$p: license"
	d="$(depends "$f")"
	[ "$d" = "$2" ] && ok "$p: depends: $d" || bad "$p: depends '$d', expected '$2'"
	[ "$(scripts "$f")" = "$3" ] && ok "$p: scripts: $3" || bad "$p: scripts '$(scripts "$f")', expected '$3'"
	mkdir -p "$T/$p"
	"$APK" extract --allow-untrusted --destination "$T/$p" "$f" >/dev/null 2>&1 && ok "$p: extracted" || bad "$p: apk extract failed"
	echo "   $(sha256sum "$f" | cut -d' ' -f1)  $(basename "$f") ($(stat -c %s "$f") bytes, installed $(info "$f" installed-size) bytes)"
}
# has PKG FILE [x]: the package ships FILE (x: executable)
has() {
	local f="$T/$1/$2"
	if [ -f "$f" ] && { [ "${3:-}" != x ] || [ -x "$f" ]; }; then ok "$1 ships /$2${3:+ (executable)}"; else bad "$1 does not ship /$2${3:+ executable}"; fi
}
hasnot() { if [ -e "$T/$1/$2" ]; then bad "$1 must not ship /$2"; else ok "$1 does not ship /$2"; fi; }

# sub-packages without a postrm of their own
ALL="post-install post-upgrade pre-deinstall"
check_pkg easy-vless "coreutils coreutils-base64 coreutils-nohup coreutils-timeout curl ip-full kmod-nft-nat kmod-nft-socket kmod-nft-tproxy libc libuci-lua lua luci-compat luci-lib-jsonc lyaml nftables openssl-util resolveip" \
	"post-deinstall post-install post-upgrade pre-deinstall pre-install pre-upgrade"
for f in usr/share/easy_vless/app.sh usr/share/easy_vless/utils.sh usr/share/easy_vless/nftables.sh usr/share/easy_vless/update.sh \
	usr/share/easy_vless/subscribe.lua usr/share/easy_vless/diag.lua usr/share/easy_vless/backup.lua usr/share/easy_vless/lease2hosts.sh \
	usr/lib/lua/luci/easy_vless/api.lua etc/init.d/easy_vless etc/uci-defaults/easy-vless etc/hotplug.d/iface/98-easy-vless; do
	has easy-vless "$f" x
done
for f in usr/share/easy_vless/0_default_config usr/share/easy_vless/direct_ip usr/share/easy_vless/resources/manifest.json \
	lib/upgrade/keep.d/easy-vless lib/apk/packages/easy-vless.list lib/apk/packages/easy-vless.conffiles; do
	has easy-vless "$f"
done
grep -qx /usr/share/easy_vless/direct_ip "$T/easy-vless/lib/apk/packages/easy-vless.conffiles" 2>/dev/null \
	&& ok "easy-vless: direct_ip is a conffile" || bad "easy-vless: direct_ip not in conffiles"
hasnot easy-vless usr/lib/lua/luci/easy_vless/util_sing-box.lua
hasnot easy-vless usr/lib/lua/luci/easy_vless/util_xray.lua
for f in manifest.json domains/proxy.txt domains/russia.txt; do
	cmp -s "$T/easy-vless/usr/share/easy_vless/resources/$f" "$W/root/usr/share/easy_vless/resources/$f" \
		&& ok "easy-vless: resources/$f byte-identical to the source" || bad "easy-vless: resources/$f differs from the source"
done

check_pkg easy-vless-sing-box "easy-vless libc sing-box" "$ALL"
has easy-vless-sing-box usr/lib/lua/luci/easy_vless/util_sing-box.lua
has easy-vless-sing-box usr/share/easy_vless/clash_api.lua
hasnot easy-vless-sing-box usr/lib/lua/luci/easy_vless/util_xray.lua

check_pkg easy-vless-xray "easy-vless libc xray-core" "$ALL"
has easy-vless-xray usr/lib/lua/luci/easy_vless/util_xray.lua
hasnot easy-vless-xray usr/lib/lua/luci/easy_vless/util_sing-box.lua

check_pkg easy-vless-geodata "easy-vless geoview libc v2ray-geoip v2ray-geosite" "$ALL"

check_pkg luci-app-easy-vless "easy-vless libc luci-base rpcd" "post-deinstall post-install post-upgrade pre-deinstall"
for f in main servers rules settings wizard diagnostics maintenance; do has luci-app-easy-vless "www/luci-static/resources/view/easy_vless/$f.js"; done
for f in www/luci-static/resources/easy_vless/common.js www/luci-static/resources/easy_vless/rulecheck.js \
	usr/share/luci/menu.d/luci-app-easy-vless.json usr/share/rpcd/acl.d/luci-app-easy-vless.json usr/lib/lua/luci/i18n/easy-vless.ru.lmo; do
	has luci-app-easy-vless "$f"
done
has luci-app-easy-vless usr/libexec/rpcd/luci.easy_vless x
hasnot luci-app-easy-vless usr/share/easy_vless
python3 "$W/scripts/po2lmo.py" "$W/luci/po/ru/easy-vless.po" "$T/ru.lmo" \
	&& cmp -s "$T/ru.lmo" "$T/luci-app-easy-vless/usr/lib/lua/luci/i18n/easy-vless.ru.lmo" \
	&& ok "luci-app-easy-vless: easy-vless.ru.lmo matches luci/po/ru/easy-vless.po" || bad "luci-app-easy-vless: easy-vless.ru.lmo differs"

echo "===== apk package check ($V): PASS: $PASS  FAIL: $FAIL ====="
[ "$FAIL" -eq 0 ]
