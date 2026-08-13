################################################################################
#
# radioctl
#
################################################################################

RADIOCTL_VERSION = 1.0.0
RADIOCTL_SITE = $(BR2_EXTERNAL_ZYBO_Z7_PATH)/package/radioctl/src
RADIOCTL_SITE_METHOD = local
RADIOCTL_LICENSE = GPL-2.0-or-later

define RADIOCTL_BUILD_CMDS
	$(MAKE) CC="$(TARGET_CC)" CFLAGS="$(TARGET_CFLAGS)" -C $(@D)
endef

define RADIOCTL_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/radioctl $(TARGET_DIR)/usr/bin/radioctl
endef

$(eval $(generic-package))
