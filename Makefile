#
# Easy VLESS - lightweight VLESS client for OpenWrt (client-only, transparent proxy)
# https://github.com/quargelk/easy-vless
# Derived from PassWall2 25.5.15-1 (commit 394f3842969161ddd888187e72db4b493b3310b4),
# https://github.com/Openwrt-Passwall/openwrt-passwall2 (GPL-3.0).
#
include $(TOPDIR)/rules.mk

PKG_NAME:=easy-vless
PKG_VERSION:=0.6.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=quargelk <332162732+quargelk@users.noreply.github.com>

include $(INCLUDE_DIR)/package.mk

# This package ships only shell/Lua sources, static config templates and
# service/hotplug scripts - there is no PKG_SOURCE and no real build step.
# package.mk's default Build/Compile (Build/Compile/Default) unconditionally
# runs "$(MAKE) -C $(PKG_BUILD_DIR) ..." and fails with "No targets specified
# and no makefile found" for a source-less package like this one. Every real
# upstream LuCI app package avoids this the same way: feeds/luci/luci.mk
# defines an empty Build/Compile (conditionally there, unconditionally here
# since we never have a src/ subdirectory). Verified directly against a real,
# non-DUMP OpenWrt 24.10.3 package.mk/package-pack.mk build: without this
# override, `make -C package/easy-vless compile` fails at our own package's
# compile step; with it, all three .ipk are produced correctly.
define Build/Compile
endef

define Package/easy-vless
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Easy VLESS - lightweight VLESS transparent proxy runtime (core)
  URL:=https://github.com/quargelk/easy-vless
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
	+openssl-util \
	+lyaml
  # Backend engines (sing-box/xray) are NOT core DEPENDS - see the
  # easy-vless-sing-box / easy-vless-xray sub-packages below. This split
  # exists because the full sing-box (~40MB) does not fit the overlay on
  # small-flash devices; core + exactly one engine package must be
  # installable on its own.
  #
  # geoview/v2ray-geoip/v2ray-geosite live in the optional sub-package
  # easy-vless-geodata: geoview exists only
  # in the third-party PassWall feed, so a hard core dependency made
  # easy-vless uninstallable on a router with official feeds only. Every
  # runtime caller already degrades gracefully without them: utils.sh
  # get_geoip() returns nothing when geoview or geoip.dat is missing,
  # nftables.sh gen_shunt_list() disables geoview preloading, and
  # util_sing-box.lua check_geoview() skips .srs conversion. Rules that
  # reference geoip:/geosite: need easy-vless-geodata installed.
  # openssl-util: api.lua's fetch_cert_sha256() (Reality/TLS
  # cert pinning) shells out to `openssl s_client`/`openssl x509`. Verified
  # against the real openwrt/openwrt package/libs/openssl/Makefile: the CLI
  # binary is installed by the "openssl-util" sub-package specifically
  # (DEPENDS:=+libopenssl +libopenssl-conf, pulled in transitively) - "openssl"
  # itself is not an installable package name in OpenWrt.
  # lyaml: subscribe.lua requires "lyaml" unconditionally to parse
  # Clash-YAML subscriptions (VLESS nodes only).
  # tcping/unzip are not needed (test.sh uses plain curl; subscribe.lua has
  # no archive-format subscription support).
  # Runtime requirement that cannot be expressed as a DEPENDS: dnsmasq-full
  # (dnsmasq with nftset support) replaces the default dnsmasq package, and
  # opkg has no Provides/Conflicts relation between the two. app.sh checks
  # for nftset support at start and refuses to start with a clear error;
  # install.sh offers the replacement explicitly.
endef

define Package/easy-vless/description
  Easy VLESS is a lightweight VLESS client for OpenWrt, derived from
  PassWall2: transparent proxying with nftables/fw4 TPROXY, routing rules
  with prepared domain resources, DNS (direct/remote DNS, FakeDNS, DNS
  redirect), VLESS URL import and subscriptions (VLESS URL lists, base64,
  sing-box JSON, Clash YAML; VLESS nodes only). This is the
  engine-independent core; install easy-vless-sing-box for the VLESS engine
  and luci-app-easy-vless for the web interface. Needs dnsmasq-full (nftset
  support) at runtime.
endef

# --- Backend sub-packages ---
# Each engine is its own installable unit so a device that cannot fit both
# backends can install core + exactly one engine. easy-vless-sing-box is the
# supported engine (the web interface and URL Test groups are sing-box based);
# easy-vless-xray is optional. app.sh's acl_node() reports a clear error per
# node when no usable engine is installed.

define Package/easy-vless-geodata
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Easy VLESS - GeoIP/GeoSite data for Shunt Rules
  URL:=https://github.com/quargelk/easy-vless
  PKGARCH:=all
  DEPENDS:=+easy-vless +geoview +v2ray-geoip +v2ray-geosite
endef

define Package/easy-vless-geodata/description
  Meta package pulling in geoview and the v2ray geoip.dat/geosite.dat
  datasets used by Shunt Rules entries of the form geoip:<code> and
  geosite:<code>. geoview is provided by the third-party PassWall package
  feed, not by the official OpenWrt feeds. Not needed for plain VLESS
  proxying.
endef

# Meta package: ships no files of its own.
define Package/easy-vless-geodata/install
	true
endef

define Package/easy-vless-sing-box
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Easy VLESS - sing-box backend
  URL:=https://github.com/quargelk/easy-vless
  PKGARCH:=all
  # NOTE: "sing-box" is intentionally NOT "+"-prefixed. The official
  # net/sing-box/Makefile ships a second variant, sing-box-tiny, which
  # declares PROVIDES:=sing-box (a "virtual package" with two providers:
  # sing-box itself and sing-box-tiny). A "+sing-box" DEPENDS makes
  # OpenWrt's Kconfig generator (scripts/package-metadata.pl:mconf_depends)
  # resolve "sing-box" through that virtual-package table and emit a
  # conditional "select PACKAGE_sing-box if PACKAGE_sing-box-tiny<...",
  # which combined with sing-box-tiny's own CONFLICTS-derived
  # "depends on ... (PACKAGE_sing-box != y)" forms a genuine Kconfig cycle:
  # PACKAGE_sing-box-tiny -> PACKAGE_sing-box -> PACKAGE_sing-box-tiny.
  # Reproduced directly against the real package-metadata.pl script.
  # A plain (non-"+") DEPENDS instead generates a simple, non-circular
  # "depends on PACKAGE_sing-box||PACKAGE_sing-box-tiny" - verified to
  # eliminate the cycle. The "+" flag only affects Kconfig/image-build
  # package *selection*; it has zero effect on the real .ipk's Depends:
  # control-file field (include/package-pack.mk strips every "+" before
  # writing Depends:), so `opkg install easy-vless-sing-box` on a router
  # still pulls in "sing-box" exactly as before - no behavior change.
  DEPENDS:=+easy-vless sing-box
endef

define Package/easy-vless-sing-box/description
  sing-box backend for Easy VLESS: VLESS over TCP/raw, TLS, Reality, WS,
  gRPC, HTTPUpgrade, plus the AUTO group (sing-box urltest). Required for
  AUTO/URLTest nodes - Xray has no equivalent mechanism in this project.
  Depends on the virtual package "sing-box" (provided by sing-box or
  sing-box-tiny >= 1.12). Includes the Clash API client used by LuCI to
  read and trigger URL Test results of the running instance.
endef

define Package/easy-vless-xray
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Easy VLESS - Xray backend
  URL:=https://github.com/quargelk/easy-vless
  PKGARCH:=all
  # The real opkg package name in the official openwrt/packages feed is
  # "xray-core", not "xray" (net/xray-core/Makefile:
  # $$(eval $$(call BuildPackage,xray-core))). The binary it installs is named
  # /usr/bin/xray (matching app.sh's `first_type ... xray` binary lookup),
  # but the DEPENDS token must be the real package name - verified directly
  # against the pinned feed commit, not assumed.
  # "xray-core" also uses no "+" prefix, for the same reason and for
  # consistency with easy-vless-sing-box above, even though xray-core has
  # no PROVIDES-based variant sibling in the official feed today (verified:
  # no cycle reproduced for it specifically). Same zero-effect-on-real-
  # Depends: guarantee applies (see comment above).
  DEPENDS:=+easy-vless xray-core
endef

define Package/easy-vless-xray/description
  Optional Xray backend for Easy VLESS: VLESS over TCP/raw, TLS, Reality, WS,
  gRPC, HTTPUpgrade, XHTTP and mKCP (XHTTP/mKCP nodes need Xray). Not part of
  the standard installation: the web interface has no Xray-specific
  settings, and URL Test groups require sing-box. With xray-core installed,
  newly imported VLESS links may be created as Xray nodes.
endef

# --- LuCI UI sub-package ---
# Kept in this Makefile (like the backend sub-packages) so the existing
# standalone CI build keeps producing every .ipk from one source tree.
# Plain package.mk (not feeds/luci/luci.mk): no translations/minification
# yet, hence no luci-base/host build dependency. Files live under ./luci/.
define Package/luci-app-easy-vless
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI interface for Easy VLESS
  URL:=https://github.com/quargelk/easy-vless
  PKGARCH:=all
  DEPENDS:=+easy-vless +luci-base +rpcd
endef

define Package/luci-app-easy-vless/description
  Web interface for Easy VLESS: Main (service control and status, rule
  targets, connection test), Node List (VLESS servers, VLESS URL
  import/export, URL subscriptions with HAPP User-Agent and HWID, URL Test
  groups), Rule Manage (routing rules, prepared domain resources) and
  Settings (DNS, forwarding). Talks to the runtime through the rpcd plugin
  luci.easy_vless.
endef

define Package/easy-vless/conffiles
/etc/config/easy_vless
/usr/share/easy_vless/direct_ip
endef

# Core package contents: runtime shell layer, init/hotplug scripts, the Lua
# layer under /usr/lib/lua/luci/easy_vless/ (api.lua, com.lua) and the
# helpers under /usr/share/easy_vless/. The engine-specific config
# generators (util_sing-box.lua / util_xray.lua) ship in the backend
# sub-packages; app.sh's acl_node() detects at runtime which exist.
# The PassWall2 GeoIP/GeoSite downloader (rule_update.lua) is not ported:
# the datasets come from the v2ray-geoip/v2ray-geosite packages
# (easy-vless-geodata).
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
	$(INSTALL_BIN) ./root/usr/share/easy_vless/lease2hosts.sh $(1)/usr/share/easy_vless/lease2hosts.sh
	$(INSTALL_DATA) ./root/usr/share/easy_vless/direct_ip $(1)/usr/share/easy_vless/direct_ip

	# Prepared resources (0.5.0): manifest + domain lists, referenced from
	# UCI by id (shunt_rules.domain_resource), read by api.lua.
	$(INSTALL_DIR) $(1)/usr/share/easy_vless/resources/domains
	$(INSTALL_DATA) ./root/usr/share/easy_vless/resources/manifest.json $(1)/usr/share/easy_vless/resources/manifest.json
	$(INSTALL_DATA) ./root/usr/share/easy_vless/resources/domains/proxy.txt $(1)/usr/share/easy_vless/resources/domains/proxy.txt
	$(INSTALL_DATA) ./root/usr/share/easy_vless/resources/domains/russia.txt $(1)/usr/share/easy_vless/resources/domains/russia.txt

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/easy_vless
	$(INSTALL_BIN) ./root/usr/lib/lua/luci/easy_vless/api.lua $(1)/usr/lib/lua/luci/easy_vless/api.lua
	$(INSTALL_BIN) ./root/usr/lib/lua/luci/easy_vless/com.lua $(1)/usr/lib/lua/luci/easy_vless/com.lua

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

	# sysupgrade keeps the persisted subscription HWID (/etc/easy_vless/hwid)
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./root/lib/upgrade/keep.d/easy-vless $(1)/lib/upgrade/keep.d/easy-vless
endef

define Package/easy-vless/postinst
#!/bin/sh
# /etc/uci-defaults/easy-vless is executed and then removed by OpenWrt's
# default_postinst (/lib/functions.sh) before this script runs; it must not
# be sourced again here. default_postinst also enables /etc/init.d/easy_vless
# (offline via rc.common in IPKG_INSTROOT, live via "enable"); the explicit
# enable below is kept for the live install and is idempotent.
[ -n "$${IPKG_INSTROOT}" ] || {
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

define Package/easy-vless/postrm
#!/bin/sh
# After a real removal only (on an upgrade the new app.sh is already in
# place): drop the fw4 include and the ucitrack entry added by
# /etc/uci-defaults/easy-vless, so no stale reference is left behind.
[ -n "$${IPKG_INSTROOT}" ] || [ -e /usr/share/easy_vless/app.sh ] || {
	uci -q delete firewall.easy_vless && uci -q commit firewall
	if [ -e /etc/config/ucitrack ]; then
		while uci -q get ucitrack.@easy_vless[-1] >/dev/null; do
			uci -q delete ucitrack.@easy_vless[-1]
		done
		uci -q commit ucitrack
	fi
	rm -f /var/etc/easy_vless.include
}
exit 0
endef

define Package/easy-vless-sing-box/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/easy_vless
	$(INSTALL_BIN) ./root/usr/lib/lua/luci/easy_vless/util_sing-box.lua $(1)/usr/lib/lua/luci/easy_vless/util_sing-box.lua

	$(INSTALL_DIR) $(1)/usr/share/easy_vless
	$(INSTALL_BIN) ./root/usr/share/easy_vless/clash_api.lua $(1)/usr/share/easy_vless/clash_api.lua
endef

define Package/easy-vless-xray/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/easy_vless
	$(INSTALL_BIN) ./root/usr/lib/lua/luci/easy_vless/util_xray.lua $(1)/usr/lib/lua/luci/easy_vless/util_xray.lua
endef

define Package/luci-app-easy-vless/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/easy_vless
	$(INSTALL_DATA) ./luci/htdocs/luci-static/resources/view/easy_vless/main.js $(1)/www/luci-static/resources/view/easy_vless/main.js
	$(INSTALL_DATA) ./luci/htdocs/luci-static/resources/view/easy_vless/servers.js $(1)/www/luci-static/resources/view/easy_vless/servers.js
	$(INSTALL_DATA) ./luci/htdocs/luci-static/resources/view/easy_vless/rules.js $(1)/www/luci-static/resources/view/easy_vless/rules.js
	$(INSTALL_DATA) ./luci/htdocs/luci-static/resources/view/easy_vless/settings.js $(1)/www/luci-static/resources/view/easy_vless/settings.js
	$(INSTALL_DATA) ./luci/htdocs/luci-static/resources/view/easy_vless/wizard.js $(1)/www/luci-static/resources/view/easy_vless/wizard.js

	$(INSTALL_DIR) $(1)/www/luci-static/resources/easy_vless
	$(INSTALL_DATA) ./luci/htdocs/luci-static/resources/easy_vless/common.js $(1)/www/luci-static/resources/easy_vless/common.js

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./luci/root/usr/share/luci/menu.d/luci-app-easy-vless.json $(1)/usr/share/luci/menu.d/luci-app-easy-vless.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./luci/root/usr/share/rpcd/acl.d/luci-app-easy-vless.json $(1)/usr/share/rpcd/acl.d/luci-app-easy-vless.json

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./luci/root/usr/libexec/rpcd/luci.easy_vless $(1)/usr/libexec/rpcd/luci.easy_vless
endef

# Reload rpcd so the new ubus object luci.easy_vless and its ACL are known,
# and drop LuCI's menu/module caches (same steps as feeds/luci/luci.mk).
define Package/luci-app-easy-vless/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
exit 0
endef

define Package/luci-app-easy-vless/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
exit 0
endef

$(eval $(call BuildPackage,easy-vless))
$(eval $(call BuildPackage,easy-vless-sing-box))
$(eval $(call BuildPackage,easy-vless-xray))
$(eval $(call BuildPackage,easy-vless-geodata))
$(eval $(call BuildPackage,luci-app-easy-vless))