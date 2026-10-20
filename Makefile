CC = clang
CFLAGS = -std=c11 -O2 -Wall -Wextra -Werror
ARCHS ?=
ARCHFLAGS = $(foreach arch,$(ARCHS),-arch $(arch))
APPFLAGS = -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0
FRAMEWORKS = -framework Cocoa -framework UserNotifications -framework ServiceManagement -framework IOKit -framework CoreFoundation
APP = build/XGlyph.app
BINARY = $(APP)/Contents/MacOS/XGlyph
LOCALIZATIONS = $(wildcard app/Resources/*.lproj/*.strings)

.PHONY: all app test test-app clean
all: app
app: $(BINARY)

build/AppIcon.icns: app/Assets/XGlyph-icon.png tools/build-icon.sh
	sh tools/build-icon.sh

$(BINARY): app/XGlyph.m app/Info.plist app/BatteryProtocol.h app/NotificationPolicy.h build/AppIcon.icns LICENSE $(LOCALIZATIONS) Makefile
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	$(CC) $(APPFLAGS) $(ARCHFLAGS) app/XGlyph.m $(FRAMEWORKS) -o $@
	cp app/Info.plist $(APP)/Contents/Info.plist
	cp build/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp LICENSE $(APP)/Contents/Resources/LICENSE.txt
	cp -R app/Resources/*.lproj $(APP)/Contents/Resources/
	codesign --force --sign - $(APP)

build/test-protocol: tests/test_protocol.c app/BatteryProtocol.h
	mkdir -p build
	$(CC) $(CFLAGS) tests/test_protocol.c -o $@

build/test-notifications: tests/test_notifications.c app/NotificationPolicy.h
	mkdir -p build
	$(CC) $(CFLAGS) tests/test_notifications.c -o $@

test: test-app
test-app: app build/test-protocol build/test-notifications
	./build/test-protocol
	./build/test-notifications
	$(BINARY) --self-test
	python3 tests/test_localization.py

clean:
	rm -rf build

.PHONY: test-layout
test-layout: app build/LocalizationPreview.app/Contents/MacOS/Preview
	@for language in en ru de es zh-Hans; do \
		build/LocalizationPreview.app/Contents/MacOS/Preview -AppleLanguages "($$language)" || exit $$?; \
	done

build/LocalizationPreview.app/Contents/MacOS/Preview: tests/render_app.m $(BINARY)
	mkdir -p build/LocalizationPreview.app/Contents/MacOS
	$(CC) $(APPFLAGS) $(ARCHFLAGS) tests/render_app.m $(FRAMEWORKS) -o $@
	cp -R $(APP)/Contents/Resources build/LocalizationPreview.app/Contents/
	cp app/Info.plist build/LocalizationPreview.app/Contents/Info.plist
	/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Preview' build/LocalizationPreview.app/Contents/Info.plist
	/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.gnineteen.xglyph.preview' build/LocalizationPreview.app/Contents/Info.plist
