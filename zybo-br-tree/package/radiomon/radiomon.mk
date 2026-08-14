################################################################################
#
# radiomon
#
################################################################################

RADIOMON_VERSION = 1.0.0
RADIOMON_SITE = $(BR2_EXTERNAL_ZYBO_Z7_PATH)/package/radiomon/src
RADIOMON_SITE_METHOD = local
RADIOMON_LICENSE = GPL-2.0-or-later
# plot_lib.hpp is vendored from fbbdev/plot, which is MIT.
RADIOMON_LICENSE_FILES =

define RADIOMON_BUILD_CMDS
	$(MAKE) CXX="$(TARGET_CXX)" CXXFLAGS="$(TARGET_CXXFLAGS)" -C $(@D)
endef

define RADIOMON_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/radiomon $(TARGET_DIR)/usr/bin/radiomon
endef

$(eval $(generic-package))
