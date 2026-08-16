#!/bin/bash
# Проверка Фазы 1 (§9): захват 120 строк с паузой 0.7 с, дедупликация,
# эвристика секретов, чёрный список источников.
# Запускать при работающем ClipMouse. Буфер обмена после прогона затирается.
set -euo pipefail

DB="$HOME/Library/Application Support/ClipMouse/clipmouse.sqlite"
DOMAIN="dev.zeklop.clipmouse"
FAILED=0

count() { sqlite3 "$DB" "select count(*) from clips;"; }
has_preview() { [ "$(sqlite3 "$DB" "select count(*) from clips where preview like '$1%';")" -gt 0 ]; }

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILED=1; }

echo "== 1. 120 копирований с паузой 0.7 с (~84 с) =="
before=$(count)
for i in $(seq 1 120); do
  printf "тестовая строка номер %03d" "$i" | pbcopy
  sleep 0.7
done
sleep 2
after=$(count)
added=$((after - before))
if [ "$added" -eq 120 ]; then ok "захвачено 120 из 120 (счётчик $before → $after)"; else fail "захвачено $added из 120 (счётчик $before → $after)"; fi
[ "$after" -le 200 ] && ok "потолок history.limit не превышен ($after)" || fail "счётчик выше 200: $after"

echo "== 2. повтор того же текста не растит счётчик =="
c1=$(count)
printf "тестовая строка номер 001" | pbcopy; sleep 1.5
printf "тестовая строка номер 001" | pbcopy; sleep 1.5
c2=$(count)
[ "$c1" -eq "$c2" ] && ok "счётчик не изменился ($c1)" || fail "счётчик вырос: $c1 → $c2"

echo "== 3. эвристика секретов =="
printf 'ghp_phase1selftest16C7e42F291cZv5' | pbcopy; sleep 1.5
c3=$(count)
if has_preview "ghp_"; then fail "секрет с ghp_ попал в историю"; else ok "секрет с ghp_ не сохранён"; fi
[ "$c3" -eq "$c2" ] && ok "счётчик не изменился ($c3)" || fail "счётчик изменился: $c2 → $c3"

echo "== 4. чёрный список источников =="
defaults write "$DOMAIN" security.blockedSources -array "dev.zcode.app"
sleep 1
printf "заблокированная строка номер один" | pbcopy
sleep 2
if has_preview "заблокированная"; then fail "клип из блокированного источника сохранён"; else ok "блокированный источник пропущен"; fi
defaults delete "$DOMAIN" security.blockedSources
# кеш UserDefaults обновляется через cfprefsd не мгновенно — ждём до 10 с
printf "разблокированная строка номер два" | pbcopy
captured=0
for _ in $(seq 1 10); do
  sleep 1
  if has_preview "разблокированная"; then captured=1; break; fi
done
[ "$captured" -eq 1 ] && ok "после снятия блокировки захват возобновился" || fail "захват не возобновился"

echo "== 5. затираем тестовые данные из буфера =="
printf ' ' | pbcopy

if [ "$FAILED" -eq 0 ]; then echo "PHASE1 CHECK OK"; else echo "PHASE1 CHECK FAILED"; exit 1; fi
