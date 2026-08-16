# Подпись кода и права TCC — полная инструкция

Самая дорогая по токенам часть проекта. Здесь всё, что было выстрадано
16.08.2026, — чтобы следующий агент не повторял. Ключевой документ по
симптомам: план §9 Фаза 3, блок «Прогон 16.08.2026».

## Зачем вообще подпись

Право **Accessibility** (Universal Access) macOS привязывает к подписи приложения:

- **adhoc-подпись** («подписать как попало») → требование = `cdhash`,
  хеш конкретного бинаря. Любая пересборка = «другое приложение» → право слетает.
- **сертификатная подпись** → требование = `certificate leaf = H"…"`,
  переживает любые пересборки, пока подпись ставится тем же сертификатом.

Проверить, какая у бандла подпись:

```bash
codesign -dv --verbose=2 /Applications/ClipMouse.app
# хорошо: Authority=ClipMouse Dev, CodeDirectory flags=0x0(none)
# плохо:  Signature=adhoc, flags=0x2(adhoc)

codesign -d --requirements - /Applications/ClipMouse.app
# хорошо: designated => identifier "dev.zeklop.clipmouse"
#                  and certificate leaf = H"9423…"
# плохо:  designated => cdhash H"…"   ← привязка к сборке
```

## Создание сертификата с нуля

1. `bash scripts/make-cert.sh` — openssl генерирует ключ+сертификат
   (`ClipMouse Dev`, RSA-2048, 3650 дней). `-days` обязателен: без него
   сертификат живёт 30 дней и всё слетит через месяц. EKU=codeSigning
   задаётся через openssl-конфиг в скрипте (не через `-addext` — LibreSSL
   из /usr/bin его не понимает).
2. Импорт в login keychain (паролей не спрашивает, если цепочка разблокирована):
   ```bash
   security import .build/codesign/clipmouse.key -k ~/Library/Keychains/login.keychain-db
   security import .build/codesign/clipmouse.pem  -k ~/Library/Keychains/login.keychain-db
   ```
3. **Доверие сертификату НЕ нужно.** `sudo security add-trusted-cert …` —
   это для Gatekeeper (запуск скачанного); локальной подписи и TCC доверие
   не требуется. Проверено: codesign подписывает, TCC работает.

## Подпись в проекте

Makefile сам находит сертификат и подписывает ВСЕМИ целями (sign, install):

```make
SIGN_PRESENT := $(shell security find-certificate -c "ClipMouse Dev" >/dev/null 2>&1 && echo yes)
ifeq ($(SIGN_PRESENT),yes)
SIGN_IDENTITY := ClipMouse Dev
else
SIGN_IDENTITY := -
endif
```

**Грабля №1 (главная).** Раньше `make install` внутри ре-подписывал бандл
дефолтным `SIGN_IDENTITY ?= -` и молча затирал сертификатную подпись adhoc-подписью.
Симптом: право Accessibility выдано, тумблер в настройках **включён**, а
`AXIsProcessTrusted()` в приложении — false; после каждой пересборки всё умирает.
Классический рассинхрон TCC-базы и UI System Settings (см. Stack Overflow
«AXIsProcessTrustedWithOptions doesn't return true even when the app is ticked»).
Никогда не делайте `SIGN_IDENTITY ?= -` с установкой отдельным таргетом.

**Грабля №2.** Детект сертификата: `security find-identity -v -p codesigning`
**не видит** наш сертификат (0 valid identities — он без доверия), хотя codesign
им подписывает. Искать надо `security find-certificate -c "ClipMouse Dev"`.

## Грабля №3: залипшая TCC-запись

Симптомы: тумблер включён, право не действует; удаление строки и добавление
заново через «+» не помогает (или помогает до первой пересборки).
Диагностика приложения: лог `AX при старте: …` при каждом запуске.

Лечение:

```bash
tccutil reset Accessibility dev.zeklop.clipmouse
```

затем выдать право заново (тумблер / «+»). После этого запись держится по
требованию подписи и переживает пересборки.

**Промпт `AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt)` не
показывается, пока в списке уже есть запись** — даже мёртвая запись блокирует
системный диалог. Сначала reset/удаление, потом запрос.

В приложении за это отвечает `Core/Permissions.swift`: опрос раз в 2 с,
переход false→true пересоздаёт хоткеи и ремап, маркер `~/Library/Application
Support/ClipMouse/.ax-granted` (ключей Defaults сверх §7 не заводим) + алерт
с кнопкой Request при «право было и пропало».

## Грабля №4: responsible process (кому принадлежит право)

TCC приписывает право **«ответственному» процессу**. Поэтому:

- запуск бинаря из терминала (`.../ClipMouse --paste-test`) → ответственный
  = терминал (zcode/Terminal) → у бинаря права НЕТ, постинг тихо не доходит;
- запуск через `open` / LaunchServices → ответственный = само приложение →
  право работает.

Следствие: любая диагностика, связанная с постингом событий (⌘V, правый
Command), обязана идти **из GUI-инстанса**. Для этого в main.swift есть env-режимы:

```bash
open --env CLIPMOUSE_SPIKE=1 /Applications/ClipMouse.app        # спайк правого ⌘
open --env CLIPMOUSE_PASTE_TEST=1 /Applications/ClipMouse.app   # ⌘V в активное окно через 4 с
```

(Apple-event URL-схема тоже приходит в GUI-инстанс — `clipmouse://caffeine/…`.)

## Хронология инцидента 16.08.2026 (для распознавания в будущем)

1. adhoc-сборка, право выдано на «+»-строку → привязка к cdhash.
2. Первая пересборка пережилась (кэш tccd), вторая — нет: `AX при старте: нет`.
3. Пользователь дважды пересоздавал строку — не помогало (install продолжал
   ре-подписывать adhoc).
4. Диагноз через `codesign -dv --verbose=2` установленного бандла: `Signature=adhoc`
   при том, что repo-бандл был подписан сертификатом.
5. Фикс Makefile (автодетект) + `tccutil reset` + выдача → «Accessibility выдан»
   в логах, переживает пересборки (проверено touch+install+restart).

## Чек-лист «права слетели»

1. `codesign -dv --verbose=2 /Applications/ClipMouse.app | grep Authority`
   → нет `ClipMouse Dev`? Пересобрать `make install`, смотреть п. «Подпись».
2. Подпись верная, а `AX при старте: нет` → `tccutil reset Accessibility
   dev.zeklop.clipmouse`, выдать заново.
3. Право есть, но постинг из тестового CLI не работает → это нормально
   (responsible process), проверять через `open --env`.
4. `IsSecureEventInputEnabled() == true` (Bitwarden открыт, Terminal с
   Secure Keyboard Entry) → синтетический ⌘V не дойдёт, приложение покажет
   «Press ⌘V manually». Это не баг.
