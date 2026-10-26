APP_NAME := AIQuotaBar
BUILD_DIR ?= /tmp/AIQuotaBar-build
DIST_DIR := dist
APP := $(BUILD_DIR)/$(APP_NAME).app
EXECUTABLE := $(APP)/Contents/MacOS/$(APP_NAME)
SOURCES := $(wildcard Sources/AIQuotaBar/*.swift)
ICON := Resources/$(APP_NAME).icns
CODESIGN_IDENTITY ?= -

.PHONY: all app test selftest benchmark snapshot diagnostics dmg clean

all: app

app: $(ICON)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(DIST_DIR)"
	swiftc -O $(SOURCES) -o "$(EXECUTABLE)" -framework AppKit -framework ApplicationServices -framework Security -framework JavaScriptCore
	cp Info.plist "$(APP)/Contents/Info.plist"
	cp "$(ICON)" "$(APP)/Contents/Resources/$(APP_NAME).icns"
	cp README.md "$(APP)/Contents/Resources/README.md"
	cp -R Scripts "$(APP)/Contents/Resources/Scripts"
	chmod +x "$(APP)/Contents/Resources/Scripts/"*.sh
	xattr -cr "$(APP)"
	xattr -d com.apple.FinderInfo "$(APP)" 2>/dev/null || true
	xattr -d 'com.apple.fileprovider.fpfs#P' "$(APP)" 2>/dev/null || true
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" "$(APP)"

# 默认测试：完全本地、确定性，不触碰 Chrome、不读用户会话内容。
test: app
	plutil -lint "$(APP)/Contents/Info.plist"
	codesign --verify --deep --strict "$(APP)"
	"$(EXECUTABLE)" --version
	"$(EXECUTABLE)" --self-test

selftest: app
	"$(EXECUTABLE)" --self-test

# 本机统计性能基准：冷/热缓存耗时、读取字节、解析行数、峰值内存。只输出聚合值。
benchmark: app
	"$(EXECUTABLE)" --benchmark

# 需要 Chrome 自动化权限，会 reload 已打开的额度页；不在默认 test 里。
snapshot: app
	"$(EXECUTABLE)" --print-snapshot

# 浏览器实例诊断：候选 PID / 分类 / 选中 PID / 枚举计数 / 阶段错误；不 reload、不执行页面 JS、不输出正文。
diagnostics: app
	"$(EXECUTABLE)" --browser-diagnostics

dmg: app
	rm -f "$(DIST_DIR)/$(APP_NAME).dmg"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(APP)" -ov -format UDZO "$(DIST_DIR)/$(APP_NAME).dmg"

$(ICON): Scripts/generate-app-icon.swift Resources/$(APP_NAME)IconSource.png
	mkdir -p Resources
	swift Scripts/generate-app-icon.swift Resources

clean:
	rm -rf "$(BUILD_DIR)" "$(DIST_DIR)"
