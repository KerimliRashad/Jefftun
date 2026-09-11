"""Генерация конфигурации xray и применение изменений (перезапуск контейнера)."""
import json
import base64
from urllib.parse import quote
from app import config


def build_config(users: list) -> dict:
    """Собирает полный config.json xray из списка активных пользователей."""
    enabled = [u for u in users if u.enabled]

    vless_clients = [{"id": u.uuid, "email": u.name, "flow": "xtls-rprx-vision"} for u in enabled]
    vmess_clients = [{"id": u.uuid, "email": u.name} for u in enabled]
    trojan_clients = [{"password": u.secret, "email": u.name} for u in enabled]
    # Shadowsocks 2022 требует один метод; используем общий пароль-схему через несколько пользователей
    ss_clients = [{"password": u.secret, "email": u.name, "method": "aes-128-gcm"} for u in enabled]

    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "vless-reality",
                "listen": "0.0.0.0",
                "port": config.PORT_REALITY,
                "protocol": "vless",
                "settings": {"clients": vless_clients, "decryption": "none"},
                "streamSettings": {
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": {
                        "show": False,
                        "dest": f"{config.REALITY_SNI}:443",
                        "xver": 0,
                        "serverNames": [config.REALITY_SNI],
                        "privateKey": config.REALITY_PRIVATE_KEY,
                        "shortIds": [config.REALITY_SHORT_ID],
                    },
                },
                "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
            },
            {
                "tag": "vmess-ws",
                "listen": "0.0.0.0",
                "port": config.PORT_VMESS_WS,
                "protocol": "vmess",
                "settings": {"clients": vmess_clients},
                "streamSettings": {"network": "ws", "wsSettings": {"path": "/vm"}},
            },
            {
                "tag": "trojan",
                "listen": "0.0.0.0",
                "port": config.PORT_TROJAN,
                "protocol": "trojan",
                "settings": {"clients": trojan_clients},
                "streamSettings": {"network": "tcp", "security": "none"},
            },
            {
                "tag": "shadowsocks",
                "listen": "0.0.0.0",
                "port": config.PORT_SHADOWSOCKS,
                "protocol": "shadowsocks",
                "settings": {"clients": ss_clients, "network": "tcp,udp"},
            },
        ],
        "outbounds": [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"},
        ],
    }


def write_config(users: list):
    cfg = build_config(users)
    with open(config.XRAY_CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)


def reload_xray():
    """Перезапускает контейнер xray чтобы применить новый конфиг."""
    try:
        import docker
        client = docker.from_env()
        for c in client.containers.list(all=True):
            name = c.name.lower()
            if "xray" in name:
                c.restart(timeout=5)
                return True
    except Exception as e:
        print(f"[xray] reload failed: {e}")
    return False


def apply(users: list):
    write_config(users)
    reload_xray()


# ── Генерация клиентских ссылок для подписки ──────────────────────────────────
def vless_link(u) -> str:
    d = config.PANEL_DOMAIN
    params = (
        f"type=tcp&security=reality&pbk={config.REALITY_PUBLIC_KEY}"
        f"&fp=chrome&sni={config.REALITY_SNI}&sid={config.REALITY_SHORT_ID}"
        f"&flow=xtls-rprx-vision"
    )
    return f"vless://{u.uuid}@{config.SERVER_IP}:{config.PORT_REALITY}?{params}#{quote('JeffTUN VLESS ' + u.name)}"


def vmess_link(u) -> str:
    obj = {
        "v": "2", "ps": f"JeffTUN VMess {u.name}", "add": config.SERVER_IP,
        "port": str(config.PORT_VMESS_WS), "id": u.uuid, "aid": "0",
        "net": "ws", "type": "none", "host": "", "path": "/vm", "tls": "",
    }
    return "vmess://" + base64.b64encode(json.dumps(obj).encode()).decode()


def trojan_link(u) -> str:
    return f"trojan://{u.secret}@{config.SERVER_IP}:{config.PORT_TROJAN}?security=none&type=tcp#{quote('JeffTUN Trojan ' + u.name)}"


def ss_link(u) -> str:
    userinfo = base64.b64encode(f"aes-128-gcm:{u.secret}".encode()).decode()
    return f"ss://{userinfo}@{config.SERVER_IP}:{config.PORT_SHADOWSOCKS}#{quote('JeffTUN SS ' + u.name)}"


def server_vless_link(u, s) -> str:
    """VLESS-REALITY ссылка на конкретный сервер-страну s для юзера u."""
    params = (
        f"type=tcp&security=reality&pbk={s.public_key}"
        f"&fp=chrome&sni={s.sni}&sid={s.short_id}&flow={s.flow}"
    )
    return f"vless://{u.uuid}@{s.host}:{s.port}?{params}#{quote(s.name)}"


def subscription_body(u, servers=None) -> str:
    """Подписка (base64). Если переданы серверы — по ссылке на каждую страну.
    Иначе — 4 протокола локального узла (обратная совместимость)."""
    if servers:
        links = [server_vless_link(u, s) for s in servers]
    else:
        links = [vless_link(u), vmess_link(u), trojan_link(u), ss_link(u)]
    return base64.b64encode("\n".join(links).encode()).decode()
