TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# roothide/rootless
THEOS_PACKAGE_SCHEME = rootless

# 关键修复: 不链接 CydiaSubstrate (roothide 环境无此框架, dyld 拒载)
# MSHookMessageEx 等符号运行时由 ElleKit 提供
SUBSTRATE =

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidifyUnlock
LiquidifyUnlock_FILES = Tweak.xm
LiquidifyUnlock_FRAMEWORKS = UIKit Foundation CoreGraphics
LiquidifyUnlock_PRIVATE_FRAMEWORKS =
LiquidifyUnlock_CFLAGS = -fobjc-arc
LiquidifyUnlock_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
