include $(TOPDIR)/rules.mk

LUCI_NAME:=luci-app-shoulderx
LUCI_TITLE:=ShoulderX — Xray config from a subscription
LUCI_DESCRIPTION:=LuCI page for shoulderX: paste a subscription URL, pick a mode \
(obhod BS / home internet), choose per-section community lists and let it rebuild \
the Xray config.
LUCI_DEPENDS:=+shoulderx
LUCI_PKGARCH:=all

PKG_MAINTAINER:=shoulderX
PKG_LICENSE:=MIT
PKG_VERSION:=0.3.3
PKG_RELEASE:=1

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
