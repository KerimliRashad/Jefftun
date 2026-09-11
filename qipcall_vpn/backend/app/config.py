import os
import secrets as _secrets

# Секреты берутся ТОЛЬКО из переменных окружения (.env), в коде их нет.
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql+asyncpg://vpn:vpnpass@db:5432/vpndb")
# Если не задан — генерируется случайный при старте (токены станут невалидны при перезапуске)
SECRET_KEY = os.getenv("SECRET_KEY") or _secrets.token_hex(32)
# Пароль админки: обязателен через окружение. Если не задан — случайный (в логах),
# чтобы никто не мог войти со «стандартным» паролем.
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD") or _secrets.token_urlsafe(12)

PANEL_DOMAIN = os.getenv("PANEL_DOMAIN", "localhost")
SERVER_IP = os.getenv("SERVER_IP", "127.0.0.1")

# REALITY параметры (генерируются скриптом setup.sh)
REALITY_PRIVATE_KEY = os.getenv("REALITY_PRIVATE_KEY", "")
REALITY_PUBLIC_KEY = os.getenv("REALITY_PUBLIC_KEY", "")
REALITY_SHORT_ID = os.getenv("REALITY_SHORT_ID", "0123abcd")
REALITY_SNI = os.getenv("REALITY_SNI", "www.microsoft.com")

# Порты inbound'ов xray
PORT_REALITY = 443
PORT_VMESS_WS = 2053
PORT_TROJAN = 2083
PORT_SHADOWSOCKS = 8388

# Путь к конфигу xray (общий volume с контейнером xray)
XRAY_CONFIG_PATH = os.getenv("XRAY_CONFIG_PATH", "/app/xray/config.json")
