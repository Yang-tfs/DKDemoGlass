#
#  DKDemoGlass —— iOS 16 磨砂胶囊底栏最小验证
#
#  目标环境：iPhone 13 Pro Max / iOS 16.3.1 / TrollStore 2 + TrollFools（无越狱）
#
#  所以这里不产 deb：TrollFools 注入的是一枚 dylib，靠 dyld 在 App 启动时加载。
#  构建只依赖 Logos 的 internal 生成器（纯 ObjC runtime swizzle），不需要 CydiaSubstrate / ElleKit。
#

TARGET = iphone:clang:latest:15.0
# 抖音 App 二进制是 arm64；只出 arm64 一片，避免 TrollFools 处理 fat 二进制时的多余变量。
ARCHS = arm64

INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DKDemoGlass

DKDemoGlass_FILES = src/DKDemoGlassCapsule.m src/DKDemoTabBar.xm
DKDemoGlass_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/src -Wall
DKDemoGlass_FRAMEWORKS = UIKit QuartzCore Foundation
DKDemoGlass_LOGOS_DEFAULT_GENERATOR = internal

# TrollFools 把注入的 dylib 放在 App 包里的 Frameworks/ 下，用 @executable_path 引用。
# 若注入后启动即闪退、日志报 "image not found"，把它改成 @executable_path/DKDemoGlass.dylib 重出一次。
DKDemoGlass_INSTALL_NAME ?= @executable_path/Frameworks/DKDemoGlass.dylib

include $(THEOS_MAKE_PATH)/tweak.mk

# TrollFools 用的产物：一枚自包含 dylib。
dylib::
	@$(MAKE) all
	@mkdir -p packages
	@DYLIB=$$(find .theos/obj -name 'DKDemoGlass.dylib' | head -1); \
	if [ -z "$$DYLIB" ]; then echo "error: 找不到 DKDemoGlass.dylib"; exit 1; fi; \
	cp -f "$$DYLIB" packages/DKDemoGlass.dylib; \
	if command -v install_name_tool >/dev/null 2>&1; then \
		install_name_tool -id "$(DKDemoGlass_INSTALL_NAME)" packages/DKDemoGlass.dylib || true; \
	fi; \
	if command -v ldid >/dev/null 2>&1; then ldid -S packages/DKDemoGlass.dylib || true; fi
	@echo "==> 产物: packages/DKDemoGlass.dylib"

# 越狱环境才用得上，TrollFools 不需要。
package-rootless::
	@rm -rf .theos
	@$(MAKE) all package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
