#!/usr/bin/env bash
# Обновляет SHA256 в Cask-формуле по собранному DMG.
# Использование: scripts/update-cask-sha.sh

set -euo pipefail

DMG=".build/ClipMouse-$(grep -A1 CFBundleShortVersionString Resources/Info.plist | tail -1 | sed 's/.*<string>//;s/<.*//').dmg"
CASK="packaging/Casks/clipmouse.rb"

if [ ! -f "$DMG" ]; then
  echo "DMG не найден: $DMG. Сначала: make dmg" >&2
  exit 1
fi

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "SHA256: $SHA"

if command -v sed >/dev/null 2>&1; then
  sed -i '' "s/sha256 \".*\"/sha256 \"$SHA\"/" "$CASK"
  echo "Обновлено: $CASK"
else
  echo "sed не найден — обновите SHA256 вручную в $CASK"
fi
