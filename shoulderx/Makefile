include $(TOPDIR)/rules.mk

PKG_NAME:=shoulderx
PKG_VERSION:=0.3.3
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=shoulderX

include $(INCLUDE_DIR)/package.mk

define Package/shoulderx
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Xray config generator from a subscription
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-uci +curl +ca-bundle
  PKGARCH:=all
endef

define Package/shoulderx/description
  ShoulderX downloads an Xray-JSON subscription (Remnawave/Happ) and builds a
  ready Xray client config: socks inbound, one outbound per server, leastPing
  balancer, and RKN whitelist routed direct.

  It exists because some provider servers speak only Xray: the same VLESS +
  REALITY + gRPC node that works in Xray 26.x is dropped by sing-box 1.14.
  If podkop is installed, point its section at the socks inbound
  (127.0.0.1:20180) and it will use this tunnel.
endef

define Package/shoulderx/conffiles
/etc/config/shoulderx
endef

define Package/shoulderx/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	[ -f /etc/init.d/shoulderx.apk-new ] && mv -f /etc/init.d/shoulderx.apk-new /etc/init.d/shoulderx
	/etc/init.d/shoulderx enable >/dev/null 2>&1
}
exit 0
endef

define Package/shoulderx/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	[ -f /etc/init.d/shoulderx.apk-new ] && mv -f /etc/init.d/shoulderx.apk-new /etc/init.d/shoulderx
	/usr/bin/shoulderx schedule off >/dev/null 2>&1
	/etc/init.d/shoulderx disable >/dev/null 2>&1
}
exit 0
endef

define Build/Compile
endef

define Package/shoulderx/install
	$(INSTALL_DIR) \
		$(1)/etc/config \
		$(1)/etc/init.d \
		$(1)/usr/bin \
		$(1)/usr/lib/shoulderx

	$(INSTALL_CONF) ./files/etc/config/shoulderx $(1)/etc/config/shoulderx
	$(INSTALL_BIN)  ./files/etc/init.d/shoulderx $(1)/etc/init.d/shoulderx
	$(INSTALL_BIN)  ./files/usr/bin/shoulderx $(1)/usr/bin/shoulderx
	$(INSTALL_BIN)  ./files/etc/init.d/shoulderx-xray $(1)/etc/init.d/shoulderx-xray
	$(INSTALL_DATA) ./files/usr/lib/shoulderx/*.uc $(1)/usr/lib/shoulderx/
	echo "$(PKG_VERSION)-r$(PKG_RELEASE)" > $(1)/usr/lib/shoulderx/version
endef

$(eval $(call BuildPackage,shoulderx))

