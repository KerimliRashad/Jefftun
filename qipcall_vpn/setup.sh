#!/usr/bin/env bash
# JeffTUN VPN — первичная настройка. Запускать один раз в папке qipcall_vpn.
set -e

DOMAIN="${1:-localhost}"
SERVER_IP="${2:-$(curl -s https://api.ipify.org || echo 127.0.0.1)}"
SNI="${3:-www.microsoft.com}"

# Пароль админки: берётся из окружения ADMIN_PASSWORD, иначе генерируется случайно
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 14)}"
DB_PASSWORD="$(openssl rand -hex 12)"

echo "==> Генерация ключей REALITY через xray..."
KEYS=$(docker run --rm teddysun/xray:latest xray x25519)
PRIV=$(echo "$KEYS" | grep -i private | awk '{print $NF}')
PUB=$(echo "$KEYS" | grep -i password -i -e public | awk '{print $NF}')
# у разных версий разные подписи полей — подстрахуемся
[ -z "$PRIV" ] && PRIV=$(echo "$KEYS" | sed -n '1p' | awk '{print $NF}')
[ -z "$PUB" ]  && PUB=$(echo "$KEYS" | sed -n '2p' | awk '{print $NF}')
SHORT_ID=$(openssl rand -hex 4)

echo "==> Запись .env..."
cat > .env <<EOF
PANEL_DOMAIN=$DOMAIN
SERVER_IP=$SERVER_IP
REALITY_SNI=$SNI
REALITY_PRIVATE_KEY=$PRIV
REALITY_PUBLIC_KEY=$PUB
REALITY_SHORT_ID=$SHORT_ID
DB_PASSWORD=$DB_PASSWORD
ADMIN_PASSWORD=$ADMIN_PASSWORD
SECRET_KEY=$(openssl rand -hex 32)
EOF
chmod 600 .env 2>/dev/null || true

echo "==> Открываю порты в firewall (если ufw включён)..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow 443/tcp   || true
  ufw allow 80/tcp    || true
  ufw allow 8443/tcp  || true
  ufw allow 2053/tcp  || true
  ufw allow 2083/tcp  || true
  ufw allow 8388/tcp  || true
  ufw allow 8388/udp  || true
fi

echo ""
echo "════════════════════════════════════════════"
echo " Готово! Параметры записаны в .env"
echo "  Домен:        $DOMAIN"
echo "  IP:           $SERVER_IP"
echo "  REALITY SNI:  $SNI"
echo "  Public key:   $PUB"
echo "  Short ID:     $SHORT_ID"
echo "════════════════════════════════════════════"
echo ""
echo "Дальше:  docker compose up --build -d"
echo "Панель:  https://$DOMAIN:8443/admin"
echo ""
echo "  🔑 ПАРОЛЬ АДМИНКИ (сохрани, показывается один раз):"
echo "      $ADMIN_PASSWORD"
echo "  (хранится только в .env на сервере, в коде его нет)"
echo "════════════════════════════════════════════"
