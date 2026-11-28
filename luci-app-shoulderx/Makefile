include $(TOPDIR)/rules.mk

LUCI_NAME:=luci-app-shoulderx
LUCI_TITLE:=ShoulderX — Xray config from a subscription
LUCI_DESCRIPTION:=LuCI page for shoulderX: paste a subscription URL and let it \
rebuild the Xray config (bypass mode: everything to the tunnel, RU whitelist direct).
LUCI_DEPENDS:=+shoulderx
LUCI_PKGARCH:=all

PKG_MAINTAINER:=shoulderX
PKG_LICENSE:=MIT
PKG_VERSION:=0.7.0
PKG_RELEASE:=1

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
