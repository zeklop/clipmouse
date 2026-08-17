APP := ClipMouse.app
BUNDLE_ID := dev.zeklop.clipmouse
ICNS := .build/AppIcon.icns
# Если в цепочке есть наш сертификат — подписываем им всегда (включая
# install, который раньше молча перезатирал подпись adhoc — замерено
# 2026-08-16: из-за этого право Accessibility слетало на каждой пересборке).
# Замерено: find-identity -v сертификат не видит (нет доверия), а codesign
# им подписывает — поэтому ищем сертификат, а не identity
SIGN_PRESENT := $(shell security find-certificate -c "ClipMouse Dev" >/dev/null 2>&1 && echo yes)
ifeq ($(SIGN_PRESENT),yes)
SIGN_IDENTITY := ClipMouse Dev
else
SIGN_IDENTITY := -
endif
BUILD_LOG := .build/build.log
RELEASE_LOG := .build/build-release.log

# VERSION строго до DMG: := разворачивается в момент объявления
VERSION := $(shell grep -A1 CFBundleShortVersionString Resources/Info.plist | tail -1 | sed 's/.*<string>//;s/<.*//')
DMG := .build/ClipMouse-$(VERSION).dmg

.PHONY: build build-release bundle sign install dmg selftest check clean

# Ворнинги = провал сборки (§3). pipefail нужен, чтобы провал swift build
# не съедался tee в конце конвейера.
build:
	@mkdir -p .build
	@set -o pipefail; swift build 2>&1 | tee $(BUILD_LOG)
	@if grep -q "warning:" $(BUILD_LOG); then echo "FATAL: ворнинги в debug-сборке"; exit 1; fi

# install собирает release: публичная установка — оптимизированный бинарь
build-release:
	@mkdir -p .build
	@set -o pipefail; swift build -c release 2>&1 | tee $(RELEASE_LOG)
	@if grep -q "warning:" $(RELEASE_LOG); then echo "FATAL: ворнинги в release-сборке"; exit 1; fi

bundle: build-release $(ICNS)
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@cp .build/release/ClipMouse $(APP)/Contents/MacOS/ClipMouse
	@cp Resources/Info.plist $(APP)/Contents/Info.plist
	@cp $(ICNS) $(APP)/Contents/Resources/AppIcon.icns
	@cp -R Resources/*.lproj $(APP)/Contents/Resources/

# Иконка: из точных координат StatusIcon (§9 Фаза 6)
$(ICNS): scripts/make-icon.swift
	@mkdir -p .build/AppIcon.iconset
	@swiftc -O scripts/make-icon.swift -o .build/make-icon
	@./.build/make-icon .build/icon_1024.png
	@for s in 16 32 128 256 512; do \
	  sips -z $$s $$s .build/icon_1024.png --out .build/AppIcon.iconset/icon_$$s\x$$s.png >/dev/null 2>&1; \
	  d=$$((s*2)); \
	  sips -z $$d $$d .build/icon_1024.png --out .build/AppIcon.iconset/icon_$$s\x$$s@2x.png >/dev/null 2>&1; \
	done
	@iconutil -c icns .build/AppIcon.iconset -o $(ICNS)
	@echo "icns: $(ICNS)"

# По умолчанию — adhoc; после Ч1: make sign SIGN_IDENTITY='ClipMouse Dev'
sign: bundle
	@codesign --force --sign "$(SIGN_IDENTITY)" $(APP)
	@codesign --verify --strict $(APP)

install: sign
	@rm -rf /Applications/$(APP)
	@cp -R $(APP) /Applications/
	@echo "Установлено: /Applications/$(APP)"

# DMG для дистрибуции (GitHub Releases / Homebrew Cask).
# Классическая раскладка: копия .app + симлинк на /Applications —
# пользователь перетаскивает приложение на symlink. Симлинки вместо
# копии самого .app недостаточно: hdiutil запакует ссылку, не бандл.
dmg: sign
	@mkdir -p .build/dmg-staging
	@rm -rf .build/dmg-staging/$(APP) .build/dmg-staging/Applications
	@cp -R $(APP) .build/dmg-staging/$(APP)
	@ln -s /Applications .build/dmg-staging/Applications
	@rm -f $(DMG)
	@hdiutil create -volname ClipMouse -srcfolder .build/dmg-staging \
		-ov -fs HFS+ -format UDZO $(DMG)
	@rm -rf .build/dmg-staging
	@echo "DMG: $(DMG) ($$(du -h $(DMG) | cut -f1))"

selftest: build
	@./.build/debug/ClipMouse --selftest

# Спайк Ч3: сборка утилиты правого Command (запускает человек, Фаза 4)
spike:
	@mkdir -p .build
	@swiftc -O scripts/spike-right-cmd.swift -o .build/spike-right-cmd
	@echo "Спайк собран: .build/spike-right-cmd — запускать человеку при выключенном правиле Karabiner"

check: build
	@set -o pipefail; swift build -c release 2>&1 | tee $(RELEASE_LOG)
	@if grep -q "warning:" $(RELEASE_LOG); then echo "FATAL: ворнинги в release-сборке"; exit 1; fi
	@$(MAKE) selftest

clean:
	@rm -rf .build $(APP) $(DMG)
