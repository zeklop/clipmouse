#!/usr/bin/env bash
# ClipMouse — быстрый установщик для macOS (Apple Silicon).
# Использование: curl -fsSL https://zeklop.github.io/clipmouse/install.sh | bash
set -euo pipefail

APP_NAME="ClipMouse"
BUNDLE_ID="dev.zeklop.clipmouse"
VERSION="0.2.0"
MINIMUM_MACOS="26"
DMG_URL="https://github.com/zeklop/clipmouse/releases/download/v${VERSION}/ClipMouse-${VERSION}.dmg"
EXPECTED_SHA256="2ba80668576cc7f843f99b25ef019e996aaffd214361ca23ff60fea32d422424"
DEST_APP="/Applications/${APP_NAME}.app"

# Цвета терминала
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
DIM='\033[0;90m'
RESET='\033[0m'

say() { printf "%b▸%b %s\n" "$CYAN" "$RESET" "$1"; }
ok() { printf "%b✓%b %s\n" "$GREEN" "$RESET" "$1"; }
warn() { printf "%b!%b %s\n" "$YELLOW" "$RESET" "$1"; }
fail() { printf "%b✗ %s%b\n" "$RED" "$1" "$RESET" >&2; exit 1; }

# Проверка платформы
[ "$(uname -s)" = "Darwin" ] || fail "Установщик работает только на macOS."

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64) ;;
  x86_64) fail "ClipMouse требует Mac с процессором Apple Silicon (arm64). Архитектура Intel (x86_64) не поддерживается." ;;
  *) fail "Неизвестная архитектура: ${HOST_ARCH}." ;;
esac

MACOS_MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
case "$MACOS_MAJOR" in ''|*[!0-9]*) fail "Не удалось определить версию macOS." ;; esac
[ "$MACOS_MAJOR" -ge "$MINIMUM_MACOS" ] || fail "Требуется macOS ${MINIMUM_MACOS} или новее (у вас macOS ${MACOS_MAJOR})."

TMP_DIR="$(/usr/bin/mktemp -d -t clipmouse-install.XXXXXX)"
MOUNT_DIR="${TMP_DIR}/mount"
cleanup() {
  if [ -d "$MOUNT_DIR" ]; then
    /usr/bin/hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

DMG_FILE="${TMP_DIR}/${APP_NAME}.dmg"

say "Скачиваю ClipMouse ${VERSION}…"
/usr/bin/curl --fail --location --silent --show-error --retry 3 \
  --connect-timeout 15 "$DMG_URL" --output "$DMG_FILE"

ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$DMG_FILE" | /usr/bin/awk '{print $1}')"
[ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ] || fail "Контрольная сумма SHA-256 не совпала. Установка остановлена."
ok "SHA-256 подтверждён (${ACTUAL_SHA256:0:12}…)"

say "Монтирую образ диска…"
/bin/mkdir -p "$MOUNT_DIR"
/usr/bin/hdiutil attach "$DMG_FILE" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null

SOURCE_APP="${MOUNT_DIR}/${APP_NAME}.app"
[ -d "$SOURCE_APP" ] || fail "В образе DMG не найден ${APP_NAME}.app."

FOUND_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
[ "$FOUND_ID" = "$BUNDLE_ID" ] || fail "Некорректный Bundle ID: ${FOUND_ID:-не найден}."

# Закрыть запущенный инстанс при обновлении
/usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
/bin/sleep 1

say "Устанавливаю в /Applications…"
NEEDS_SUDO=0
[ -w /Applications ] || NEEDS_SUDO=1

if [ "$NEEDS_SUDO" -eq 1 ]; then
  say "macOS требует пароль администратора для записи в /Applications."
  /usr/bin/sudo -v
  /usr/bin/sudo /bin/rm -rf "$DEST_APP"
  /usr/bin/sudo /usr/bin/ditto "$SOURCE_APP" "$DEST_APP"
  /usr/bin/sudo /usr/bin/xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
else
  /bin/rm -rf "$DEST_APP"
  /usr/bin/ditto "$SOURCE_APP" "$DEST_APP"
  /usr/bin/xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
fi

# Размонтировать DMG
/usr/bin/hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true

INSTALLED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST_APP/Contents/Info.plist" 2>/dev/null || true)"
[ "$INSTALLED_ID" = "$BUNDLE_ID" ] || fail "Проверка установленного приложения не пройдена."

say "Запускаю ClipMouse…"
/usr/bin/open "$DEST_APP"

printf "\n%b✓ Готово!%b ClipMouse ${VERSION} установлен и запущен.\n" "$GREEN" "$RESET"
printf "%b▸ Не забудьте выдать разрешения (буфер обмена и Универсальный доступ) в Системных настройках.%b\n\n" "$DIM" "$RESET"
