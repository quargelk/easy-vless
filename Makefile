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
	+geoview \
	+v2ray-geoip \
	+v2ray-geosite \
	+openssl-util \
	+lyaml
  # Backend engines (sing-box/xray) are NOT core DEPENDS - see the
  # easy-vless-sing-box / easy-vless-xray sub-packages below. This split
  # exists because sing-box alone (~40MB) does not fit the overlay on some
  # supported devices (e.g. Cudy WR3000E, ~37MB free); a user who only needs
  # one backend must be able to install core + exactly one engine package.
  # See decisions.md for the full dependency-split rationale.
  #
  # geoview/v2ray-geoip/v2ray-geosite added in Phase 2: decisions.md #3 keeps
  # GeoIP/GeoSite for RUSSIA->DIRECT, and utils.sh's get_geoip() /
  # nftables.sh's Shunt Rules code (gen_shunt_list(), add_firewall_rule())
  # call the real "geoview" binary at runtime. This is core (not backend-
  # specific): Shunt Rules' geoip: nftset population works purely through
  # nftables.sh/utils.sh regardless of which engine (if any) is installed.
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
  Node List, HTTP URL Test, AUTO group (sing-box urltest only), Shunt Rules,
  DNS/FakeDNS/DNS Redirect and nftables/TPROXY transparent proxying. This is
  the backend-independent core (runtime shell/Lua layer, no VLESS engine);
  install easy-vless-sing-box and/or easy-vless-xray for an actual backend.
  The LuCI UI ships separately as luci-app-easy-vless.
endef

# --- Backend sub-packages ---
# Each engine is its own installable unit so a device that cannot fit both
# backends (e.g. sing-box's ~40MB on a ~37MB-free overlay) can install core +
# exactly one engine. Both are optional; at least one must be installed for
# any node to actually run (app.sh's acl_node() guard reports a clear error
# per-node otherwise - see decisions.md).

define Package/easy-vless-sing-box
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Easy VLESS - sing-box backend
  URL:=
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
endef

define Package/easy-vless-xray
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Easy VLESS - Xray backend
  URL:=
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
  Xray backend for Easy VLESS: VLESS over TCP/raw, TLS, Reality, WS, gRPC,
  HTTPUpgrade, XHTTP and mKCP. Required for XHTTP/mKCP transport nodes -
  sing-box does not support them in this project.
endef

define Package/easy-vless/conffiles
/etc/config/easy_vless
endef

# --- Phase 2: runtime shell layer + init/hotplug. ---
# --- Phase 3: Lua layer under /usr/lib/lua/luci/easy_vless/ (api.lua,
# com.lua) and the remaining shell-adjacent Lua/shell helpers under
# /usr/share/easy_vless/ (i18n.lua, app_acl.lua, helper_dnsmasq.lua,
# subscribe.lua, test.sh), all of which app.sh/nftables.sh already
# reference by path.
# NOTE: rule_update.lua (GeoIP/GeoSite dataset updater, referenced by
# app.sh's cron-registration code) is NOT YET PORTED - see Phase 3 report /
# decisions.md for the open question about whether it's still needed given
# the v2ray-geoip/v2ray-geosite DEPENDS added in Phase 2.
# --- Backend split (this commit): util_sing-box.lua and util_xray.lua moved
# out of this package into easy-vless-sing-box / easy-vless-xray below -
# see decisions.md for the dependency-split rationale (sing-box overlay
# footprint vs. limited-flash devices). app.sh's acl_node() detects at
# runtime which of $UTIL_SINGBOX/$UTIL_XRAY actually exist on disk.
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
# $$(1) below is opkg's own postinst-script substitution (not a Make
# variable) - escaped as $$(1) so Make's own macro expansion doesn't
# silently strip the literal text "$(1)" when this comment is emitted
# (confirmed via a real, non-DUMP build: without the extra "$", the "$(1)"
# text vanishes from the built postinst-pkg script; harmless here since it
# is inside a shell comment, but kept correct for clarity).
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

define Package/easy-vless-sing-box/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/easy_vless
	$(INSTALL_BIN) ./root/usr/lib/lua/luci/easy_vless/util_sing-box.lua $(1)/usr/lib/lua/luci/easy_vless/util_sing-box.lua
endef

define Package/easy-vless-xray/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/easy_vless
	$(INSTALL_BIN) ./root/usr/lib/lua/luci/easy_vless/util_xray.lua $(1)/usr/lib/lua/luci/easy_vless/util_xray.lua
endef

$(eval $(call BuildPackage,easy-vless))
$(eval $(call BuildPackage,easy-vless-sing-box))
$(eval $(call BuildPackage,easy-vless-xray))