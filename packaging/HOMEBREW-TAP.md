# Homebrew Tap: ClipMouse

> **Статус (19.08.2026):** tap создан — `zeklop/homebrew-tap`, секция
> «Создание tap-репозитория» выполнена. Замерено: свежий Homebrew требует
> явного доверия сторонним тапам — пользователю после `brew tap zeklop/tap`
> нужен ещё `brew trust zeklop/tap` (или `brew trust --cask zeklop/tap/clipmouse`),
> иначе «Refusing to load cask from untrusted tap».

## Создание tap-репозитория (один раз)

```bash
# Создать репозиторий homebrew-tap на GitHub
mkdir homebrew-tap && cd homebrew-tap
git init
mkdir Casks
cp /path/to/clipmouse/packaging/Casks/clipmouse.rb Casks/
git add . && git commit -m "Add clipmouse cask"
gh repo create zeklop/homebrew-tap --public --source=. --push
```

## Установка пользователями

```bash
brew tap zeklop/tap
brew install --cask clipmouse
```

## Обновление при релизе

1. Собрать DMG: `make dmg`
2. Обновить SHA256: `scripts/update-cask-sha.sh`
3. Проверить diff: `git diff packaging/Casks/clipmouse.rb`
4. Закоммитить и пушить в tap:
   ```bash
   cp packaging/Casks/clipmouse.rb /path/to/homebrew-tap/Casks/
   cd /path/to/homebrew-tap
   git add Casks/clipmouse.rb && git commit -m "clipmouse v0.2.0"
   git push
   ```
5. GitHub Release: `gh release create v0.2.0 .build/ClipMouse-0.2.0.dmg`
