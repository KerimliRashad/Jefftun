# JeffTUN VPN

VPN-платформа на xray-core: VLESS REALITY + XTLS Vision, VMess (ws), Trojan, Shadowsocks.
Выдаёт ссылки-подписки для Happ, v2RayTun, Streisand, NekoBox, v2rayN.

## Что внутри
- **xray** — ядро VPN (4 протокола), слушает 443 (REALITY), 2053 (VMess), 2083 (Trojan), 8388 (Shadowsocks)
- **backend** (FastAPI) — управление пользователями, генерация конфига xray, эндпоинт подписок `/sub/{token}`
- **nginx** — сайт-витрина + панель на порту 8443
- **db** (PostgreSQL) — пользователи и статистика

## Установка (на сервере)

```bash
cd qipcall_vpn
chmod +x setup.sh
./setup.sh qipcall.duckdns.org 2.26.18.209 www.microsoft.com
docker compose up --build -d
```

`setup.sh` генерирует REALITY-ключи, пишет `.env`, открывает порты.

### Настоящий SSL для панели (чтобы не ругался браузер)
```bash
docker run --rm -v qipcall_vpn_certbot_conf:/etc/letsencrypt -v qipcall_vpn_certbot_www:/var/www/certbot \
  certbot/certbot certonly --webroot -w /var/www/certbot -d qipcall.duckdns.org \
  --email kerimlicorp@gmail.com --agree-tos --no-eff-email
docker compose restart nginx
```

## Использование
- **Сайт:**   https://qipcall.duckdns.org:8443/
- **Панель:** https://ТВОЙ_ДОМЕН:8443/admin  (пароль показывается один раз при запуске setup.sh)
- **Подписка:** каждому юзеру выдаётся ссылка `/sub/{token}` — вставляешь в Happ/v2RayTun.

## Порты
| Порт | Назначение |
|------|-----------|
| 443  | VLESS REALITY (основной, маскировка под HTTPS) |
| 2053 | VMess ws |
| 2083 | Trojan |
| 8388 | Shadowsocks |
| 8443 | Панель + сайт (HTTPS) |
| 80   | Редирект + certbot |
