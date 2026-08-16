#!/bin/bash
# Ч1 (§9 Фаза 3): генерация самоподписанного сертификата подписи кода.
# Запускает ЧЕЛОВЕК. Агент этот скрипт не запускает никогда.
set -euo pipefail

NAME="ClipMouse Dev"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/codesign"
CONF="$OUT/openssl.cnf"

mkdir -p "$OUT"

# EKU=codeSigning нужен codesign; через -addext не делаем,
# чтобы работать и с LibreSSL из /usr/bin
cat > "$CONF" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_cert
prompt = no

[dn]
CN = ${NAME}

[v3_cert]
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

# -days обязателен (§9 Фаза 0): без него сертификат живёт 30 дней,
# и Accessibility слетит через месяц
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$CONF" \
  -keyout "$OUT/clipmouse.key" \
  -out "$OUT/clipmouse.pem"

chmod 600 "$OUT/clipmouse.key"
echo ""
echo "Готово:"
echo "  ключ:       $OUT/clipmouse.key"
echo "  сертификат: $OUT/clipmouse.pem"
echo ""
echo "Дальше вручную (на последнем шаге спросят пароль администратора):"
echo "  security import $OUT/clipmouse.key -k ~/Library/Keychains/login.keychain-db"
echo "  security import $OUT/clipmouse.pem -k ~/Library/Keychains/login.keychain-db"
echo "  sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain $OUT/clipmouse.pem"
echo ""
echo "Подпись бандла: make sign SIGN_IDENTITY='${NAME}'"
