#
# Easy VLESS — backend/runtime package (client-only VLESS transparent proxy)
# Derived from PassWall2 25.5.15-1 (commit 394f3842969161ddd888187e72db4b493b3310b4)
# See decisions.md for the full rationale behind every rename/removal below.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=easy-vless
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=

include $(INCLUDE_DIR)/package.mk

define Package/easy-vless
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Easy VLESS - lightweight VLESS transparent proxy runtime
  URL:=
  PKGARCH:=all
  DEPENDS:= \
	+coreutils \
	+coreutils-base64 \
	+coreutils-nohup \
	+coreutils-timeout \
	+curl \
	+ip-full \
	+libuci-lua \
	+lua \
	+luci-compat \
	+luci-lib-jsonc \
	+resolveip \
	+nftables \
	+kmod-nft-socket \
	+kmod-nft-tproxy \
	+kmod-nft-nat \
	+sing-box \
	+geoview \
	+v2ray-geoip \
	+v2ray-geosite \
	+openssl-util \
	+lyaml
  # geoview/v2ray-geoip/v2ray-geosite added in Phase 2: decisions.md #3 keeps
  # GeoIP/GeoSite for RUSSIA->DIRECT, and utils.sh's get_geoip() /
  # nftables.sh's Shunt Rules code (gen_shunt_list(), add_firewall_rule())
  # call the real "geoview" binary at runtime.
  # openssl-util added in Phase 3: api.lua's fetch_cert_sha256() (Reality/TLS
  # cert pinning) shells out to `openssl s_client`/`openssl x509`. Verified
  # against the real openwrt/openwrt package/libs/openssl/Makefile: the CLI
  # binary is installed by the "openssl-util" sub-package specifically
  # (DEPENDS:=+libopenssl +libopenssl-conf, pulled in transitively) - "openssl"
  # itself is not an installable package name in OpenWrt.
  # lyaml added in Phase 3: subscribe.lua requires "lyaml" unconditionally to
  # parse Clash-YAML subscriptions (decision: Clash-YAML subscriptions are
  # kept for VLESS nodes).
  # tcping/unzip confirmed NOT needed anywhere in the Lua layer either
  # (test.sh uses plain curl; subscribe.lua has no archive-format subscription
  # support) - intentionally left out of DEPENDS.
endef

define Package/easy-vless/description
  Easy VLESS is a reduced, VLESS-focused fork of the PassWall2 runtime:
  sing-box/Xray backends, Node List, HTTP URL Test, AUTO group (sing-box
  urltest only), Shunt Rules, DNS/FakeDNS/DNS Redirect and nftables/TPROXY
  transparent proxying. This package provides the backend/runtime only;
  the LuCI UI ships separately as luci-app-easy-vless.
endef

define Package/easy-vless/conffiles
/etc/config/easy_vless
endef

# --- Phase 2: runtime shell layer + init/hotplug. ---
# --- Phase 3 (this commit): Lua layer under /usr/lib/lua/luci/easy_vless/
# (api.lua, com.lua, util_sing-box.lua, util_xray.lua) and the remaining
# shell-adjacent Lua/shell helpers under /usr/share/easy_vless/ (i18n.lua,
# app_acl.lua, helper_dnsmasq.lua, subscribe.lua, test.sh), all of which
# app.sh/nftables.sh already reference by path.
# NOTE: rule_update.lua (GeoIP/GeoSite dataset updater, referenced by
# app.sh's cron-registration code) is NOT YET PORTED - see Phase 3 report /
# decisions.md for the open question about whether it's still needed given
# the v2ray-geoip/v2ray-geosite DEPENDS added in Phase 2.
define Package/easy-vless/install
	$(INSTALL_DIR) $(1)/usr/share/easy_vless
	$(INSTALL_DATA) ./files/0_default_config $(1)/usr/share/easy_vless/0_default_config
	$(INSTALL_BIN) ./root/usr/share/easy_vless/app.sh $(1)/usr/share/easy_vless/app.sh
	$(INSTALL_BIN) ./root/usr/share/easy_vless/utils.sh $(1)/usr/share/easy_vless/utils.sh
	$(INSTALL_BIN) ./root/usr/share/easy_vless/nftables.sh $(1)/usr/share/easy_vless/nftables.sh
	$(INSTALL_BIN) ./root/usr/share/easy_vless/i18n.lua $(1)/usr/share/easy_vless/i18n.lua
	$(INSTALL_BIN) ./root/usr/share/easy_vless/app_acl.lua $(1)/usr/share/easy_vless/app_acl.lua
	$(INSTALL_BIN) ./root/usr/share/easy_vless/helper_dnsmasq.lua $(1)/usr/share/easy_vless/helper_dnsmasq.lua
	$(INSTALL_BIN) ./root/usr/share/easy_vless/subscribe.lua $(1)/usr/share/easy_vless/subscribe.lua
	$(INSTALL_BIN) ./root/usr/share/easy_vless/test.sh $(1)/usr/share/easy_vless/test.sh

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/easy_vless
	$(INSTALL_BIN) ./root/usr/lib/lua/luci/easy_vless/api.lua $(1)/usr/lib/lua/luci/easy_vless/api.lua
	$(INSTALL_BIN) ./root/usr/lib/lua/luci/easy_vless/com.lua $(1)/usr/lib/lua/luci/easy_vless/com.lua
	$(INSTALL_BIN) ./root/usr/lib/lua/luci/easy_vless/util_sing-box.lua $(1)/usr/lib/lua/luci/easy_vless/util_sing-box.lua
	$(INSTALL_BIN) ./root/usr/lib/lua/luci/easy_vless/util_xray.lua $(1)/usr/lib/lua/luci/easy_vless/util_xray.lua

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/easy_vless $(1)/etc/init.d/easy_vless

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./root/etc/hotplug.d/iface/98-easy-vless $(1)/etc/hotplug.d/iface/98-easy-vless

	$(INSTALL_DIR) $(1)/etc/hotplug.d/ntp
	$(INSTALL_BIN) ./root/etc/hotplug.d/ntp/30-easy-vless-resync $(1)/etc/hotplug.d/ntp/30-easy-vless-resync

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/easy-vless $(1)/etc/uci-defaults/easy-vless

	$(INSTALL_DIR) $(1)/usr/share/ucitrack
	$(INSTALL_DATA) ./root/usr/share/ucitrack/easy-vless.json $(1)/usr/share/ucitrack/easy-vless.json
endef

define Package/easy-vless/postinst
#!/bin/sh
# $(1) below is opkg's own substitution (not a Make variable) - keep verbatim.
[ -n "$${IPKG_INSTROOT}" ] || {
	( . /etc/uci-defaults/easy-vless ) && rm -f /etc/uci-defaults/easy-vless
	# Register but do not auto-start: decisions.md requires PassWall2 to be
	# stopped and the smoke-test guard checks to pass first (see app.sh
	# check_other_proxy_stopped/check_fwmark_table_free). The user starts
	# Easy VLESS manually the first time.
	/etc/init.d/easy_vless enable
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
	exit 0
}
exit 0
endef

define Package/easy-vless/prerm
#!/bin/sh
# Unconditional stop before removal so `opkg remove` on a running service
# never leaves a process / nftables table / ip rule / route behind.
[ -n "$${IPKG_INSTROOT}" ] || {
	[ -x /etc/init.d/easy_vless ] && /etc/init.d/easy_vless stop >/dev/null 2>&1
	exit 0
}
exit 0
endef

$(eval $(call BuildPackage,easy-vless))
