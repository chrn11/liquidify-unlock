TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# roothide/rootless 支持
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidifyUnlock
LiquidifyUnlock_FILES = Tweak.xm
LiquidifyUnlock_FRAMEWORKS = UIKit Foundation CoreGraphics
LiquidifyUnlock_PRIVATE_FRAMEWORKS = 
LiquidifyUnlock_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
