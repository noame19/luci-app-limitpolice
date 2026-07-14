include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-limitpolice
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=luci-app-limitpolice contributors

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-limitpolice
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=Per-Device Bandwidth Policing (tc ingress police)
	# kmod-sched provides CONFIG_NET_ACT_POLICE (the `police` tc action) plus
	# the rest of "extra traffic schedulers" (PIE / ACT_IPT / ACT_PEDIT).
	# kmod-sched-core provides sch_ingress + cls_u32 (the default classifier).
	# kmod-sched-flower provides cls_flower (alternative classifier, optional).
	DEPENDS:=+kmod-sched +kmod-sched-core +kmod-sched-flower +tc
	PKGARCH:=all
endef

define Package/luci-app-limitpolice/description
	Lightweight per-device bandwidth policing using tc ingress police.
	Compatible with hardware Flow Offloading, fullcon NAT and BBR.
	No IFB, no HTB, no fq_codel, no Cake.

	Three features in one tiny package:
	  1. Real-time per-device rate limit (IP or MAC, downlink / uplink)
	  2. Per-device daily traffic quota with punitive 1 kbit block on
	     overflow (auto-lifted at 00:00 by service restart)
	  3. Read-only daily / weekly / monthly traffic report tab — backed
	     by cron-driven per-IP counter filters, no background daemon
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./files $(PKG_BUILD_DIR)/
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-limitpolice/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/usr/sbin

	$(INSTALL_CONF) ./files/etc/config/limitpolice $(1)/etc/config/
	$(INSTALL_BIN)  ./files/etc/init.d/limitpolice $(1)/etc/init.d/
	$(INSTALL_BIN)  ./files/etc/uci-defaults/99-limitpolice $(1)/etc/uci-defaults/

	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/limitpolice.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/model/cbi/limitpolice.lua      $(1)/usr/lib/lua/luci/model/cbi/
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/model/cbi/limitpolice_edit.lua $(1)/usr/lib/lua/luci/model/cbi/
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/view/limitpolice_stats.htm     $(1)/usr/lib/lua/luci/view/

	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-limitpolice.json $(1)/usr/share/luci/menu.d/

	$(INSTALL_BIN)  ./files/usr/sbin/limitpolice-quota-check  $(1)/usr/sbin/
	$(INSTALL_BIN)  ./files/usr/sbin/limitpolice-quota-reset  $(1)/usr/sbin/
	$(INSTALL_BIN)  ./files/usr/sbin/limitpolice-stats-clear $(1)/usr/sbin/
endef

# Run once on the device after opkg install. Auto-enable + restart so the
# user does not have to SSH in. Skip during chroot / ImageBuilder builds
# (IPKG_INSTROOT is non-empty in those contexts → we are running on the
# host, not on a real router, so enabling services is meaningless).
define Package/luci-app-limitpolice/postinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] && {
    /etc/init.d/limitpolice enable
    /etc/init.d/limitpolice restart
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-limitpolice))