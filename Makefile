export TARGET = iphone:clang:latest:14.0
export ARCHS = arm64 arm64e
export INSTALL_TARGET_PROCESSES = SpringBoard
export THEOS_PACKAGE_SCHEME = roothide

PACKAGE_NAME = com.minis.liquidifyunlock

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidifyUnlock
LiquidifyUnlock_FILES = Tweak.xm
LiquidifyUnlock_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
LiquidifyUnlock_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
