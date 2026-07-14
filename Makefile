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
	DEPENDS:=+kmod-sched-act-police +kmod-sched-core \
		+kmod-sched-flower +tc
	PKGARCH:=all
endef

define Package/luci-app-limitpolice/description
	Lightweight per-device bandwidth policing using tc ingress police.
	Compatible with hardware Flow Offloading, fullcon NAT and BBR.
	No IFB, no HTB, no fq_codel, no Cake.
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
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d

	$(INSTALL_CONF) ./files/etc/config/limitpolice $(1)/etc/config/
	$(INSTALL_BIN)  ./files/etc/init.d/limitpolice $(1)/etc/init.d/
	$(INSTALL_BIN)  ./files/etc/uci-defaults/99-limitpolice $(1)/etc/uci-defaults/

	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/limitpolice.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/model/cbi/limitpolice.lua      $(1)/usr/lib/lua/luci/model/cbi/
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/model/cbi/limitpolice_edit.lua $(1)/usr/lib/lua/luci/model/cbi/

	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-limitpolice.json $(1)/usr/share/luci/menu.d/
endef

$(eval $(call BuildPackage,luci-app-limitpolice))