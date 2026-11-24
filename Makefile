# iOS 8 jailbreak (rootful, MobileSubstrate). armv7 = iPhone 4s/5/5c, iPad 2/3/4/mini1; arm64 = 5s/6/6+ ...
TARGET := iphone:clang:9.3:8.0
ARCHS = armv7 arm64
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTControl
YTControl_FILES = Tweak.m
YTControl_FRAMEWORKS = UIKit GameController MediaPlayer QuartzCore
YTControl_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk
