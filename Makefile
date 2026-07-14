include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-limitpolice
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=luci-app-limitpolice contributors

LUCI_TITLE:=Per-Device Bandwidth Policing (tc ingress police)
LUCI_DESCRIPTION:=Lightweight per-device bandwidth policing using tc ingress police. \
	Compatible with Flow Offloading / fullcon NAT / BBR. No IFB, no HTB, no fq_codel.
LUCI_CATEGORY:=Network
LUCI_DEPENDS:=+kmod-sched-act-police +kmod-sched-core \
	+@KERNEL_NET_CLS_U32:kmod-sched-core \
	+@KERNEL_NET_CLS_FLOWER:kmod-sched-flower \
	+tc
LUCI_PKGARCH:=all

include $(INCLUDE_DIR)/luci.mk

# define Build/Prepare/Compile/Package is unnecessary for pure LuCI app;
# all files live under files/ and are picked up by luci.mk.
