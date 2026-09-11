"""
Zyng VPN — десктопный клиент (Windows/Linux). Одно приложение с iOS-версией.
Слева иконки, посередине серверы с поиском, справа круглая кнопка включения.
UI: CustomTkinter. Ядро: xray-core. Системный прокси.
"""
import os
import re
import sys
import json
import time
import base64
import socket
import threading
import subprocess
import urllib.request
from urllib.parse import urlparse, parse_qs, unquote

import tkinter as tk
from tkinter import messagebox
import customtkinter as ctk

APP_NAME = "Zyng VPN"
APP_VERSION = "2.1.1"
VERSION_URL = "https://raw.githubusercontent.com/kerimlirashad/kerimlirashad/claude/icq-messenger-b0bt2n/qipcall_client/version.txt"
RELEASE_JSON_URL = "https://raw.githubusercontent.com/kerimlirashad/kerimlirashad/claude/icq-messenger-b0bt2n/qipcall_client/RELEASE.json"
RELEASES_URL = "https://github.com/kerimlirashad/kerimlirashad/releases/tag/zyng"
DOWNLOAD_BASE = "https://github.com/kerimlirashad/kerimlirashad/releases/download/zyng"
TELEGRAM_URL = "https://t.me/zyngfast"
SOCKS_PORT = 10808
HTTP_PORT = 10809
CONFIG_FILE = os.path.join(os.path.expanduser("~"), ".zyng_config.json")

# Файлы от версий, когда приложение называлось JeffTUN.
#
# Просто переименовать нельзя: в конфиге лежат ключи и подписки пользователя,
# а в hwid — идентификатор устройства. Панели с лимитом устройств считают
# именно по нему, и новый идентификатор занял бы ещё одно место в лимите, а
# старое осталось бы висеть занятым. Поэтому при первом запуске переносим и
# то, и другое, а старые файлы оставляем на месте — на случай отката.
LEGACY_CONFIG_FILE = os.path.join(os.path.expanduser("~"), ".jeffton_config.json")
LEGACY_HWID_FILE = os.path.join(os.path.expanduser("~"), ".jeffton_hwid")


def _migrate_legacy_files():
    """Переносит настройки и HWID из файлов JeffTUN. Идемпотентно."""
    import shutil
    for old_path, new_path in ((LEGACY_CONFIG_FILE, CONFIG_FILE),
                               (LEGACY_HWID_FILE,
                                os.path.join(os.path.dirname(CONFIG_FILE), ".zyng_hwid"))):
        try:
            if os.path.exists(old_path) and not os.path.exists(new_path):
                shutil.copy2(old_path, new_path)
        except Exception:
            # Перенос — удобство, а не условие работы: не вышло, значит человек
            # добавит ключи заново. Падать из-за этого на старте нельзя.
            pass


_migrate_legacy_files()

# ── Темы ──────────────────────────────────────────────────────────────────
#
# Раньше в настройках был выбор темы, но работал он вхолостую: цвета лежали
# обычными константами, а переключатель дёргал только appearance_mode самого
# CustomTkinter, который про них ничего не знает. Теперь тем четыре, и каждая
# — настоящий набор цветов.
#
# Виджеты берут цвет в момент создания, поэтому смена темы применяется при
# следующем запуске; в настройках рядом есть кнопка перезапуска.

THEMES = {
    "dark": {
        "BG": "#0E1014", "SIDE": "#12151A", "PANEL": "#171A20",
        "CARD": "#1D2129", "CARD2": "#272C36", "BORDER": "#2E343F",
        "TEXT": "#F2F5FA", "MUTED": "#8A94A6",
        "SUBCARD": "#1D2129", "SUBBORDER": "#2E343F",
        "UPDCARD": "#1D2129", "POWER_HOVER": "#272C36",
    },
    # Чистый чёрный: на OLED-мониторах и ноутбуках заметно экономит батарею.
    "black": {
        "BG": "#000000", "SIDE": "#08080A", "PANEL": "#0B0B0E",
        "CARD": "#121216", "CARD2": "#1C1C22", "BORDER": "#26262E",
        "TEXT": "#F2F5FA", "MUTED": "#8A8A99",
        "SUBCARD": "#121216", "SUBBORDER": "#26262E",
        "UPDCARD": "#121216", "POWER_HOVER": "#1C1C22",
    },
    "light": {
        "BG": "#F2F4F8", "SIDE": "#E9EDF4", "PANEL": "#FFFFFF",
        "CARD": "#FFFFFF", "CARD2": "#E9EEF7", "BORDER": "#DCE2EC",
        "TEXT": "#111318", "MUTED": "#6B7484",
        "SUBCARD": "#FFFFFF", "SUBBORDER": "#DCE2EC",
        "UPDCARD": "#FFFFFF", "POWER_HOVER": "#E9EEF7",
    },
}

def apply_theme(name):
    """Ставит палитру темы. Вызывается до сборки окна."""
    if name == "system":
        # Тёмная как основа: у CustomTkinter нет надёжного способа спросить
        # системную тему на всех платформах, а тёмная тут выглядит уместнее.
        try:
            name = "light" if ctk.get_appearance_mode().lower() == "light" else "dark"
        except Exception:
            name = "dark"
    globals().update(THEMES.get(name, THEMES["dark"]))
    # Акценты одинаковы во всех темах, только на светлом фоне чуть темнее,
    # иначе выцветают и текст по ним не читается.
    light = name == "light"
    globals().update({
        "ACC":  "#3F6FE8" if light else "#5B8CFF",
        "ACC_D": "#3358C4" if light else "#4A76DB",
        "ACC2": "#6647E0" if light else "#7A5CFF",
        "OK":   "#1FA76A" if light else "#39D98A",
        "WARN": "#C08A0A" if light else "#F0B429",
        "DANGER": "#D93B3B" if light else "#FF5C5C",
        "PING_C": "#1FA76A" if light else "#2FB37A",
        "PING_CD": "#188554" if light else "#269464",
        "UPD_C": "#3F6FE8" if light else "#5B8CFF",
        "UPD_CD": "#3358C4" if light else "#4A76DB",
        "SPEED_C": "#6647E0" if light else "#7A5CFF",
        "SPEED_CD": "#5439BE" if light else "#6647E0",
    })


# ── Язык ──────────────────────────────────────────────────────────────────

LANG = "ru"

def tr(ru, en):
    """Строка на текущем языке.

    Оба варианта стоят рядом в месте использования: видно, что увидит
    пользователь, и нельзя забыть перевод — без второго аргумента вызов просто
    не сработает.
    """
    return ru if LANG == "ru" else en


def apply_lang(name):
    global LANG
    if name == "system":
        try:
            import locale
            code = (locale.getdefaultlocale()[0] or "en")[:2].lower()
        except Exception:
            code = "en"
        name = "ru" if code == "ru" else "en"
    LANG = "ru" if name == "ru" else "en"


def _early_prefs():
    """Тема и язык нужны раньше, чем создаётся окно, — читаем их из файла сами."""
    try:
        with open(CONFIG_FILE, encoding="utf-8") as f:
            return json.load(f).get("prefs", {}) or {}
    except Exception:
        return {}


# Палитра общая с мобильным Zyng: тёмная основа, сине-фиолетовый акцент.
# Раньше тема была серо-стальной, и «включено» рисовалось тем же серым, что и
# всё остальное — состояние приходилось выискивать глазами.
BG      = "#0E1014"   # общий фон
SIDE    = "#12151A"   # боковая панель — на тон светлее фона
PANEL   = "#171A20"   # средняя панель
CARD    = "#1D2129"   # карточки
CARD2   = "#272C36"   # выбранная / вторичная
BORDER  = "#2E343F"   # тонкие рамки
ACC     = "#5B8CFF"   # акцент
ACC_D   = "#4A76DB"   # он же под курсором
ACC2    = "#7A5CFF"   # вторая половина фирменного градиента
TEXT    = "#F2F5FA"
MUTED   = "#8A94A6"
OK      = "#39D98A"   # «включено» — теперь читается сразу
WARN    = "#F0B429"
DANGER  = "#FF5C5C"
# Спец-цвета
SUBCARD   = "#1D2129"
SUBBORDER = "#2E343F"
UPDCARD   = "#1D2129"
POWER_HOVER = "#272C36"
# Цветные кнопки действий (пинг / обновление / скорость)
PING_C  = "#2FB37A"   # пинг — зелёный из той же палитры
PING_CD = "#269464"
UPD_C   = "#5B8CFF"   # обновление — основной акцент
UPD_CD  = "#4A76DB"
SPEED_C  = "#7A5CFF"  # скорость — фиолетовый, вторая половина градиента
SPEED_CD = "#6647E0"

# Максимум серверов на подписку — защита от зависания на «толстых» подписках
MAX_SERVERS = 400


def resource_path(name):
    cands = []
    if hasattr(sys, "_MEIPASS"):
        cands.append(os.path.join(sys._MEIPASS, name))
    cands.append(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), name))
    cands.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), name))
    for c in cands:
        if os.path.exists(c):
            return c
    return name


# ══ ПАРСИНГ КЛЮЧЕЙ ═══════════════════════════════════════════════════════════
def parse_link(link):
    link = link.strip()
    if link.startswith("json://"):     return _parse_jsonlink(link)
    if link.startswith("vless://"):    return _parse_vless(link)
    if link.startswith("vmess://"):    return _parse_vmess(link)
    if link.startswith("trojan://"):   return _parse_trojan(link)
    if link.startswith("ss://"):       return _parse_ss(link)
    if link.startswith(("socks://", "socks5://")): return _parse_socks(link)
    if link.startswith(("wireguard://", "wg://")): return _parse_wireguard(link)
    if link.startswith(("hysteria2://", "hy2://")):
        raise ValueError("Hysteria2 требует ядро sing-box — пока не поддерживается")
    raise ValueError("Нужен ключ vless / vmess / trojan / ss / socks5 / wireguard")


def _changelog_text(data):
    """Собирает читаемый список изменений из RELEASE.json changelog (added/fixed/known)."""
    cl = data.get("changelog") or {}
    if not isinstance(cl, dict):
        return ""
    lines = []
    for key, head in (("added", "✨ Добавлено"), ("fixed", "🛠 Исправлено"), ("known", "⚠️ Известно")):
        items = cl.get(key) or []
        if isinstance(items, list) and items:
            lines.append(head + ":")
            lines += ["  • " + str(x) for x in items]
    return "\n".join(lines)


def _parse_jsonlink(link):
    """json://<base64 outbound> — готовый xray-outbound из JSON-подписки."""
    raw = link[7:].split("#", 1)[0]
    raw += "=" * (-len(raw) % 4)
    ob = json.loads(base64.b64decode(raw).decode("utf-8", "ignore"))
    ob = dict(ob); ob["tag"] = "proxy"
    return ob


def _outbound_hostport(ob):
    """Адрес:порт из xray-outbound (vnext для vless/vmess, servers для trojan/ss/socks)."""
    try:
        st = ob.get("settings", {})
        if st.get("vnext"):
            v = st["vnext"][0]; return v.get("address"), int(v.get("port", 443))
        if st.get("servers"):
            s = st["servers"][0]; return s.get("address"), int(s.get("port", 443))
    except Exception:
        pass
    return None, None


def link_host_port(link):
    link = link.strip()
    try:
        if link.startswith("sb://"):
            ob = _parse_sblink(link)
            return ob.get("server"), int(ob.get("server_port", 443) or 443)
        if link.startswith("json://"):
            return _outbound_hostport(_parse_jsonlink(link))
        if link.startswith("vmess://"):
            raw = link[8:]; raw += "=" * (-len(raw) % 4)
            obj = json.loads(base64.b64decode(raw).decode())
            return obj.get("add"), int(obj.get("port", 443))
        # ss:// целиком в base64 — разбираем ДО urlparse.
        #
        # Классический вид: ss://BASE64#имя, где внутри «метод:пароль@хост:порт».
        # Полагаться здесь на urlparse нельзя, и это не очевидно: он не
        # возвращает пустоту, а честно считает именем хоста сам блок base64,
        # приведённый к нижнему регистру, и подставляет порт 443. Получался
        # правдоподобный мусор, и замер задержки показывал «нет ответа» для
        # живого сервера. Отличаем по «собачке»: если её нет, адрес спрятан.
        if link.lower().startswith("ss://"):
            body = link[5:].split("#", 1)[0].split("?", 1)[0]
            if "@" not in body:
                body += "=" * (-len(body) % 4)
                try:
                    plain = base64.urlsafe_b64decode(body).decode("utf-8", "replace")
                except Exception:
                    return None, None
                if "@" in plain:
                    hostpart = plain.rsplit("@", 1)[1]
                    if ":" in hostpart:
                        h, _, prt = hostpart.rpartition(":")
                        try:
                            return h, int(prt)
                        except ValueError:
                            return h, 443
                return None, None

        u = urlparse(link)
        if u.hostname:
            return u.hostname, u.port or 443
        return None, None
    except Exception:
        return None, None


COUNTRY_CODES = {
    "france": "FR", "germany": "DE", "finland": "FI", "usa": "US", "america": "US",
    "united states": "US", "malaysia": "MY", "netherlands": "NL", "holland": "NL",
    "russia": "RU", "moscow": "RU", "uk": "GB", "london": "GB", "england": "GB",
    "poland": "PL", "sweden": "SE", "turkey": "TR", "turkiye": "TR", "japan": "JP",
    "singapore": "SG", "canada": "CA", "spain": "ES", "italy": "IT", "ukraine": "UA",
    "latvia": "LV", "estonia": "EE", "lithuania": "LT", "switzerland": "CH",
    "austria": "AT", "hongkong": "HK", "hong kong": "HK", "korea": "KR", "india": "IN",
    "uae": "AE", "dubai": "AE", "kazakhstan": "KZ", "georgia": "GE",
    "malayzia": "MY",
    # расширенный список стран
    "norway": "NO", "denmark": "DK", "iceland": "IS", "ireland": "IE", "belgium": "BE",
    "portugal": "PT", "greece": "GR", "czech": "CZ", "czechia": "CZ", "slovakia": "SK",
    "hungary": "HU", "romania": "RO", "bulgaria": "BG", "serbia": "RS", "croatia": "HR",
    "slovenia": "SI", "moldova": "MD", "belarus": "BY", "armenia": "AM", "azerbaijan": "AZ",
    "cyprus": "CY", "luxembourg": "LU", "malta": "MT", "brazil": "BR", "mexico": "MX",
    "argentina": "AR", "chile": "CL", "colombia": "CO", "peru": "PE", "china": "CN",
    "taiwan": "TW", "vietnam": "VN", "thailand": "TH", "indonesia": "ID", "philippines": "PH",
    "australia": "AU", "new zealand": "NZ", "israel": "IL", "saudi": "SA", "qatar": "QA",
    "bahrain": "BH", "kuwait": "KW", "oman": "OM", "egypt": "EG", "south africa": "ZA",
    "nigeria": "NG", "morocco": "MA", "iran": "IR", "iraq": "IQ", "pakistan": "PK",
    "bangladesh": "BD", "srilanka": "LK", "nepal": "NP", "uzbekistan": "UZ",
    "kyrgyzstan": "KG", "tajikistan": "TJ", "turkmenistan": "TM", "mongolia": "MN",
    "amsterdam": "NL", "frankfurt": "DE", "helsinki": "FI", "paris": "FR", "warsaw": "PL",
    "stockholm": "SE", "vienna": "AT", "zurich": "CH", "tokyo": "JP", "seoul": "KR",
    "istanbul": "TR", "madrid": "ES", "milan": "IT", "toronto": "CA", "silicon": "US",
    # русские названия
    "москва": "RU", "россия": "RU", "спб": "RU", "питер": "RU", "петербург": "RU",
    "франкфурт": "DE", "германия": "DE", "нидерланды": "NL", "амстердам": "NL",
    "финляндия": "FI", "хельсинки": "FI", "польша": "PL", "варшава": "PL",
    "швеция": "SE", "стокгольм": "SE", "франция": "FR", "париж": "FR", "турция": "TR",
    "стамбул": "TR", "сша": "US", "америка": "US", "англия": "GB", "лондон": "GB",
    "япония": "JP", "токио": "JP", "сингапур": "SG", "канада": "CA", "испания": "ES",
    "италия": "IT", "швейцария": "CH", "австрия": "AT", "казахстан": "KZ",
    "украина": "UA", "латвия": "LV", "эстония": "EE", "литва": "LT", "корея": "KR",
    "индия": "IN", "оаэ": "AE", "дубай": "AE", "грузия": "GE", "армения": "AM",
    "норвегия": "NO", "дания": "DK", "чехия": "CZ", "бразилия": "BR",
}

# Флаги-эмодзи по коду страны
FLAGS = {
    "FR": "🇫🇷", "DE": "🇩🇪", "FI": "🇫🇮", "US": "🇺🇸", "MY": "🇲🇾", "NL": "🇳🇱",
    "RU": "🇷🇺", "GB": "🇬🇧", "PL": "🇵🇱", "SE": "🇸🇪", "TR": "🇹🇷", "JP": "🇯🇵",
    "SG": "🇸🇬", "CA": "🇨🇦", "ES": "🇪🇸", "IT": "🇮🇹", "UA": "🇺🇦", "LV": "🇱🇻",
    "EE": "🇪🇪", "LT": "🇱🇹", "CH": "🇨🇭", "AT": "🇦🇹", "HK": "🇭🇰", "KR": "🇰🇷",
    "IN": "🇮🇳", "AE": "🇦🇪", "KZ": "🇰🇿", "GE": "🇬🇪",
}


def country_of(name):
    low = (name or "").lower()
    for k, c in COUNTRY_CODES.items():
        if k in low:
            return c
    letters = "".join(ch for ch in (name or "?") if ch.isalpha())
    return (letters[:2] or "VP").upper()


def clean_name(name):
    """Убирает дублирующий код страны в начале: 'frFrance - быстрый' → 'France - быстрый'."""
    import re
    n = (name or "").strip()
    # убираем ведущие эмодзи-флаги и служебные символы
    n = re.sub(r"^[\U0001F1E6-\U0001F1FF\s\-_|·•]+", "", n)
    # 'frFrance' → 'France': только СТРОЧНЫЙ код-префикс перед заглавной буквой
    # (не трогаем 'USA', 'UK' и т.п. — они уже заглавные)
    n = re.sub(r"^[a-z]{2}(?=[A-ZА-Я])", "", n)
    return n.strip() or (name or "").strip()


def proto_line(link):
    try:
        if link.startswith("sb://"):
            ob = _parse_sblink(link)
            return f"{(ob.get('type') or 'HYSTERIA2').upper()} | SB"
        if link.startswith("json://"):
            ob = _parse_jsonlink(link)
            return f"{(ob.get('protocol') or 'VLESS').upper()} | JSON"
        scheme = link.split("://", 1)[0].upper()
        return f"{scheme} | JSON"
    except Exception:
        return "VLESS | JSON"


def _singbox_stream(ob):
    """streamSettings (xray) из sing-box tls/transport."""
    tls = ob.get("tls") or {}
    tr = ob.get("transport") or {}
    net = (tr.get("type") or "tcp").lower()
    net = {"http": "http", "httpupgrade": "httpupgrade", "ws": "ws", "grpc": "grpc",
           "quic": "quic", "xhttp": "xhttp", "": "tcp", "tcp": "tcp"}.get(net, net)
    ss = {"network": net}
    reality = tls.get("reality") or {}
    fp = ((tls.get("utls") or {}).get("fingerprint")) or "chrome"
    sni = tls.get("server_name") or (tr.get("host") if isinstance(tr.get("host"), str) else "") or ob.get("server")
    if reality.get("enabled") or reality.get("public_key"):
        ss["security"] = "reality"
        ss["realitySettings"] = {"serverName": sni, "fingerprint": fp,
                                 "publicKey": reality.get("public_key", ""),
                                 "shortId": reality.get("short_id", ""), "spiderX": ""}
    elif tls.get("enabled"):
        ss["security"] = "tls"
        ss["tlsSettings"] = {"serverName": sni, "fingerprint": fp,
                             "allowInsecure": bool(tls.get("insecure"))}
    if net == "ws":
        host = tr.get("headers", {}).get("Host") or tr.get("host") or ""
        ss["wsSettings"] = {"path": tr.get("path", "/"), "headers": {"Host": host} if host else {}}
    elif net == "grpc":
        ss["grpcSettings"] = {"serviceName": tr.get("service_name", "")}
    elif net in ("http",):
        ss["httpSettings"] = {"path": tr.get("path", "/"),
                              "host": ([tr.get("host")] if isinstance(tr.get("host"), str) else tr.get("host", []))}
    elif net in ("httpupgrade", "xhttp"):
        ss[("xhttpSettings" if net == "xhttp" else "httpupgradeSettings")] = {
            "path": tr.get("path", "/"), "host": tr.get("host", "")}
    return ss


def _singbox_to_xray(ob):
    """Конвертирует sing-box outbound → xray outbound. None если не поддерживается (hysteria2 и пр.)."""
    t = (ob.get("type") or "").lower()
    host = ob.get("server"); port = int(ob.get("server_port", 443) or 443)
    if not host:
        return None
    if t == "vless":
        return {"protocol": "vless", "settings": {"vnext": [{"address": host, "port": port,
                "users": [{"id": ob.get("uuid", ""), "encryption": "none", "flow": ob.get("flow", "")}]}]},
                "streamSettings": _singbox_stream(ob), "tag": "proxy"}
    if t == "vmess":
        return {"protocol": "vmess", "settings": {"vnext": [{"address": host, "port": port,
                "users": [{"id": ob.get("uuid", ""), "alterId": int(ob.get("alter_id", 0) or 0),
                           "security": ob.get("security", "auto")}]}]},
                "streamSettings": _singbox_stream(ob), "tag": "proxy"}
    if t == "trojan":
        return {"protocol": "trojan", "settings": {"servers": [{"address": host, "port": port,
                "password": ob.get("password", "")}]},
                "streamSettings": _singbox_stream(ob), "tag": "proxy"}
    if t == "shadowsocks":
        return {"protocol": "shadowsocks", "settings": {"servers": [{"address": host, "port": port,
                "method": ob.get("method", "aes-128-gcm"), "password": ob.get("password", "")}]}, "tag": "proxy"}
    if t == "socks":
        srv = {"address": host, "port": port}
        if ob.get("username"):
            srv["users"] = [{"user": ob.get("username", ""), "pass": ob.get("password", "")}]
        return {"protocol": "socks", "settings": {"servers": [srv]}, "tag": "proxy"}
    return None   # hysteria2/tuic и т.п. — xray не тянет, пойдут через sing-box


# Типы sing-box, которые xray НЕ умеет, но умеет само ядро sing-box
SB_ONLY_TYPES = ("hysteria2", "hysteria", "tuic")

# Все прокси-типы sing-box: подписку sing-box запускаем через её родное ядро
# БЕЗ конвертации (как в Happ) — так vless+reality+xhttp/hysteria2/tuic работают 1-в-1.
SB_PROXY_TYPES = ("vless", "vmess", "trojan", "shadowsocks", "socks", "http",
                  "hysteria", "hysteria2", "tuic", "wireguard", "shadowtls", "anytls")


def _sb_outbound(ob):
    """Готовит sing-box outbound (tag=proxy) для прямого запуска через sing-box."""
    if not ob.get("server"):
        return None
    o = dict(ob)
    o["tag"] = "proxy"
    o.pop("detour", None)
    return o


def _hy2_url_to_sb(link):
    """hysteria2://password@host:port?sni=..&insecure=1#name → sb://<base64 sing-box outbound>."""
    frag = link.split("#", 1)[1] if "#" in link else ""
    u = urlparse(link); p = parse_qs(u.query)
    ob = {"type": "hysteria2", "server": u.hostname, "server_port": u.port or 443,
          "password": unquote(u.username or "") or unquote(u.password or "")}
    sni = p.get("sni", p.get("peer", [""]))[0]
    insecure = p.get("insecure", ["0"])[0] in ("1", "true")
    ob["tls"] = {"enabled": True, "server_name": sni or u.hostname, "insecure": insecure}
    obfs = p.get("obfs", [""])[0]
    if obfs:
        ob["obfs"] = {"type": obfs, "password": p.get("obfs-password", p.get("obfs_password", [""]))[0]}
    ob["tag"] = "proxy"
    b64 = base64.b64encode(json.dumps(ob, ensure_ascii=False).encode()).decode()
    return f"sb://{b64}#{quote(unquote(frag) or (u.hostname or 'Hysteria2'))}"


def _sb_link(ob, name):
    """Упаковывает готовый sing-box outbound в псевдо-ссылку sb://<base64>#name."""
    ob = dict(ob); ob["tag"] = "proxy"
    b64 = base64.b64encode(json.dumps(ob, ensure_ascii=False).encode()).decode()
    return f"sb://{b64}#{quote(name or ob.get('server') or 'Server')}"


def _tuic_url_to_sb(link):
    """tuic://uuid:password@host:port?sni=&alpn=&congestion_control=#name → sb://."""
    frag = link.split("#", 1)[1] if "#" in link else ""
    u = urlparse(link); p = parse_qs(u.query)
    ob = {"type": "tuic", "server": u.hostname, "server_port": u.port or 443,
          "uuid": unquote(u.username or ""), "password": unquote(u.password or "")}
    sni = p.get("sni", p.get("peer", [""]))[0]
    ob["tls"] = {"enabled": True, "server_name": sni or u.hostname,
                 "insecure": p.get("allow_insecure", p.get("insecure", ["0"]))[0] in ("1", "true")}
    alpn = p.get("alpn", [""])[0]
    if alpn: ob["tls"]["alpn"] = [a for a in alpn.split(",") if a]
    cc = p.get("congestion_control", p.get("congestion_controller", [""]))[0]
    if cc: ob["congestion_control"] = cc
    urm = p.get("udp_relay_mode", [""])[0]
    if urm: ob["udp_relay_mode"] = urm
    return _sb_link(ob, unquote(frag) or u.hostname or "TUIC")


def _hysteria_url_to_sb(link):
    """hysteria://host:port?auth=&peer=&insecure=&upmbps=&downmbps=#name (v1) → sb://."""
    frag = link.split("#", 1)[1] if "#" in link else ""
    u = urlparse(link); p = parse_qs(u.query)
    ob = {"type": "hysteria", "server": u.hostname, "server_port": u.port or 443}
    auth = p.get("auth", p.get("auth_str", [""]))[0]
    if auth: ob["auth_str"] = auth
    up = p.get("upmbps", p.get("up_mbps", [""]))[0]; down = p.get("downmbps", p.get("down_mbps", [""]))[0]
    if up.isdigit(): ob["up_mbps"] = int(up)
    if down.isdigit(): ob["down_mbps"] = int(down)
    obfs = p.get("obfs", [""])[0]
    if obfs: ob["obfs"] = obfs
    sni = p.get("peer", p.get("sni", [""]))[0]
    ob["tls"] = {"enabled": True, "server_name": sni or u.hostname,
                 "insecure": p.get("insecure", ["0"])[0] in ("1", "true")}
    alpn = p.get("alpn", [""])[0]
    if alpn: ob["tls"]["alpn"] = [a for a in alpn.split(",") if a]
    return _sb_link(ob, unquote(frag) or u.hostname or "Hysteria")


def _clash_stream(p):
    """Возвращает (tls_dict, transport_dict) для sing-box из Clash-прокси."""
    tls = None
    sni_present = bool(p.get("servername") or p.get("sni") or p.get("server-name"))
    if (p.get("tls") or p.get("reality-opts") or sni_present
            or str(p.get("type", "")).lower() in ("trojan", "hysteria", "hysteria2", "tuic")):
        tls = {"enabled": True}
        sni = p.get("servername") or p.get("sni") or p.get("server-name") or p.get("server")
        if sni: tls["server_name"] = sni
        if p.get("skip-cert-verify") or p.get("insecure"):
            tls["insecure"] = True
        alpn = p.get("alpn")
        if alpn: tls["alpn"] = alpn if isinstance(alpn, list) else [alpn]
        fp = p.get("client-fingerprint")
        if fp: tls["utls"] = {"enabled": True, "fingerprint": fp}
        ro = p.get("reality-opts") or {}
        if ro:
            tls["reality"] = {"enabled": True, "public_key": ro.get("public-key", ""),
                              "short_id": ro.get("short-id", "")}
    transport = None
    net = str(p.get("network", "")).lower()
    if net == "ws":
        wo = p.get("ws-opts") or {}
        transport = {"type": "ws", "path": wo.get("path", p.get("ws-path", "/"))}
        host = (wo.get("headers") or {}).get("Host") or (wo.get("headers") or {}).get("host")
        if host: transport["headers"] = {"Host": host}
    elif net == "grpc":
        go = p.get("grpc-opts") or {}
        transport = {"type": "grpc", "service_name": go.get("grpc-service-name", "")}
    elif net in ("http", "h2"):
        ho = p.get("http-opts") or p.get("h2-opts") or {}
        transport = {"type": "http", "path": (ho.get("path") or ["/"])[0] if isinstance(ho.get("path"), list) else ho.get("path", "/")}
    return tls, transport


def _clash_to_sb(p):
    """Clash/Clash.Meta прокси (dict) → sing-box outbound. None если тип не поддержан."""
    if not isinstance(p, dict): return None
    t = str(p.get("type", "")).lower()
    server = p.get("server"); port = p.get("port")
    if not server or not port: return None
    try: port = int(port)
    except Exception: return None
    ob = {"type": t, "server": server, "server_port": port}
    tls, transport = _clash_stream(p)
    if t == "vmess":
        ob.update({"uuid": p.get("uuid", ""), "alter_id": int(p.get("alterId", p.get("alter-id", 0)) or 0),
                   "security": p.get("cipher", "auto")})
    elif t == "vless":
        ob["uuid"] = p.get("uuid", "")
        if p.get("flow"): ob["flow"] = p.get("flow")
    elif t == "trojan":
        ob["password"] = p.get("password", "")
    elif t in ("ss", "shadowsocks"):
        ob["type"] = "shadowsocks"; ob["method"] = p.get("cipher", "aes-128-gcm"); ob["password"] = p.get("password", ""); tls = None
    elif t == "hysteria2":
        ob["password"] = p.get("password", p.get("auth", ""))
        if p.get("obfs"): ob["obfs"] = {"type": p.get("obfs"), "password": p.get("obfs-password", "")}
    elif t == "hysteria":
        if p.get("auth-str") or p.get("auth_str") or p.get("auth"): ob["auth_str"] = p.get("auth-str") or p.get("auth_str") or p.get("auth")
        if str(p.get("up", "")).replace("Mbps", "").strip().isdigit(): ob["up_mbps"] = int(str(p.get("up")).replace("Mbps", "").strip())
        if str(p.get("down", "")).replace("Mbps", "").strip().isdigit(): ob["down_mbps"] = int(str(p.get("down")).replace("Mbps", "").strip())
        if p.get("obfs"): ob["obfs"] = p.get("obfs")
    elif t == "tuic":
        ob["uuid"] = p.get("uuid", ""); ob["password"] = p.get("password", "")
        if p.get("congestion-controller"): ob["congestion_control"] = p.get("congestion-controller")
        if p.get("udp-relay-mode"): ob["udp_relay_mode"] = p.get("udp-relay-mode")
    elif t in ("socks5", "socks"):
        ob["type"] = "socks"; ob["version"] = "5"
        if p.get("username"): ob["username"] = p.get("username"); ob["password"] = p.get("password", "")
        tls = None
    elif t == "http":
        if p.get("username"): ob["username"] = p.get("username"); ob["password"] = p.get("password", "")
    else:
        return None
    if tls: ob["tls"] = tls
    if transport: ob["transport"] = transport
    return ob


def _extract_clash_servers(text):
    """Достаёт серверы из Clash/Clash.Meta YAML-подписки → список sb://-ссылок."""
    if "proxies:" not in text:
        return []
    proxies = None
    try:
        import yaml
        data = yaml.safe_load(text)
        if isinstance(data, dict):
            proxies = data.get("proxies")
    except Exception:
        proxies = _yaml_proxies_fallback(text)
    if not proxies and proxies is not None:
        pass
    if proxies is None:
        proxies = _yaml_proxies_fallback(text)
    out = []
    for p in (proxies or []):
        ob = _clash_to_sb(p)
        if ob:
            out.append(_sb_link(ob, p.get("name") or ob.get("server")))
    return out


def _yaml_proxies_fallback(text):
    """Мини-парсер proxies без PyYAML: берём только inline-записи вида '- {k: v, ...}'."""
    import re as _re
    res = []
    for line in text.splitlines():
        s = line.strip()
        if not (s.startswith("- {") and s.endswith("}")):
            continue
        body = s[3:-1]
        d = {}
        for part in _re.split(r",(?![^\[]*\])", body):
            if ":" not in part: continue
            k, v = part.split(":", 1)
            k = k.strip().strip('"\''); v = v.strip().strip('"\'')
            if v.lower() in ("true", "false"): v = (v.lower() == "true")
            d[k] = v
        if d.get("server"): res.append(d)
    return res


def _parse_sblink(link):
    """sb://<base64 sing-box outbound> — готовый sing-box outbound из подписки."""
    raw = link[5:].split("#", 1)[0]
    raw += "=" * (-len(raw) % 4)
    ob = json.loads(base64.b64decode(raw).decode("utf-8", "ignore"))
    ob = dict(ob); ob["tag"] = "proxy"
    return ob


def _extract_json_servers(text):
    """Достаёт серверы из JSON-подписки: xray-формат (protocol/vnext) И sing-box (type/server).
    Возвращает список псевдо-ссылок json://<base64>#имя."""
    out = []
    try:
        obj = json.loads(text)
    except Exception:
        return out
    configs = obj if isinstance(obj, list) else [obj]
    idx = 0
    for cfg in configs:
        if not isinstance(cfg, dict):
            continue
        name = cfg.get("remarks") or cfg.get("remark") or cfg.get("ps") or cfg.get("name") or ""
        # SIP008 online-config (Outline и ss-панели): {"servers":[{server,server_port,method,password,...}]}
        srv = cfg.get("servers")
        if isinstance(srv, list) and srv and isinstance(srv[0], dict) and srv[0].get("method") and not cfg.get("outbounds"):
            for s in srv:
                if not (s.get("server") and s.get("method")):
                    continue
                sb = {"type": "shadowsocks", "server": s.get("server"),
                      "server_port": int(s.get("server_port", 8388) or 8388),
                      "method": s.get("method"), "password": s.get("password", ""), "tag": "proxy"}
                if s.get("plugin"):
                    sb["plugin"] = s.get("plugin"); sb["plugin_opts"] = s.get("plugin_opts", "")
                idx += 1
                nm = s.get("remarks") or s.get("name") or name or f"Server {idx}"
                b64 = base64.b64encode(json.dumps(sb, ensure_ascii=False).encode()).decode()
                out.append(f"sb://{b64}#{quote(nm)}")
            continue
        # одиночный ss-конфиг Outline: {"server","server_port","method","password"}
        if cfg.get("method") and cfg.get("server") and not cfg.get("type") and not cfg.get("protocol"):
            sb = {"type": "shadowsocks", "server": cfg.get("server"),
                  "server_port": int(cfg.get("server_port", 8388) or 8388),
                  "method": cfg.get("method"), "password": cfg.get("password", ""), "tag": "proxy"}
            idx += 1
            nm = name or cfg.get("server") or f"Server {idx}"
            b64 = base64.b64encode(json.dumps(sb, ensure_ascii=False).encode()).decode()
            out.append(f"sb://{b64}#{quote(nm)}")
            continue
        obs = cfg.get("outbounds")
        if not obs and (cfg.get("protocol") or cfg.get("type")):
            obs = [cfg]
        for ob in (obs or []):
            if not isinstance(ob, dict):
                continue
            xob = None; sbob = None
            if ob.get("protocol"):                       # xray-формат
                if (ob.get("protocol") or "").lower() in ("vless", "vmess", "trojan", "shadowsocks", "socks"):
                    if _outbound_hostport(ob)[0]:
                        xob = dict(ob); xob["tag"] = "proxy"
            elif ob.get("type"):                         # sing-box-формат → ядро sing-box (без конвертации)
                if (ob.get("type") or "").lower() in SB_PROXY_TYPES:
                    sbob = _sb_outbound(ob)
            if not xob and not sbob:
                continue
            idx += 1
            nm = ob.get("tag") or name or f"Server {idx}"
            if sbob:
                b64 = base64.b64encode(json.dumps(sbob, ensure_ascii=False).encode()).decode()
                out.append(f"sb://{b64}#{quote(nm)}")
            else:
                b64 = base64.b64encode(json.dumps(xob, ensure_ascii=False).encode()).decode()
                out.append(f"json://{b64}#{quote(nm)}")
    return out


def _stream(params, net, security):
    ss = {"network": net}
    if security == "reality":
        ss["security"] = "reality"
        ss["realitySettings"] = {
            "serverName": params.get("sni", [""])[0],
            "fingerprint": params.get("fp", ["chrome"])[0],
            "publicKey": params.get("pbk", [""])[0],
            "shortId": params.get("sid", [""])[0],
            "spiderX": params.get("spx", [""])[0]}
    elif security == "tls":
        ss["security"] = "tls"
        ss["tlsSettings"] = {
            "serverName": params.get("sni", [params.get("host", [""])[0]])[0],
            "fingerprint": params.get("fp", ["chrome"])[0],
            "allowInsecure": params.get("allowInsecure", ["0"])[0] in ("1", "true")}
    def one(key, default=""):
        return params.get(key, [default])[0]

    path = one("path", "/") or "/"
    host = one("host")

    # Каждому транспорту нужен свой блок настроек. Раньше их было только два —
    # ws и grpc, — а для остальных проставлялось лишь имя сети. Xray получал
    # конфиг без параметров транспорта и соединение не поднималось: сервер
    # выглядел мёртвым, хотя был полностью рабочим.
    if net == "ws":
        ss["wsSettings"] = {"path": path,
                            "headers": {"Host": host} if host else {}}
    elif net == "grpc":
        ss["grpcSettings"] = {"serviceName": one("serviceName"),
                              "multiMode": one("mode") == "multi"}
    elif net in ("xhttp", "splithttp"):
        # xhttp — нынешнее имя, splithttp — прежнее. Xray понимает оба, но
        # ключ настроек должен совпадать с именем сети.
        ss["network"] = net
        block = {"path": path, "host": host}
        if one("mode"):
            block["mode"] = one("mode")
        ss[net + "Settings"] = block
    elif net == "httpupgrade":
        ss["httpupgradeSettings"] = {"path": path, "host": host}
    elif net in ("h2", "http"):
        ss["network"] = "h2"
        ss["httpSettings"] = {"path": path,
                              "host": [h for h in host.split(",") if h]}
    elif net == "kcp":
        ss["kcpSettings"] = {"seed": one("seed"),
                             "header": {"type": one("headerType", "none") or "none"}}
    elif net == "quic":
        ss["quicSettings"] = {"security": one("quicSecurity", "none") or "none",
                              "key": one("key"),
                              "header": {"type": one("headerType", "none") or "none"}}
    elif net in ("tcp", "raw"):
        # Маскировка под обычный HTTP — у части серверов обязательна.
        if one("headerType") == "http":
            ss["tcpSettings"] = {"header": {"type": "http",
                                            "request": {"headers": {"Host": [h for h in host.split(",") if h]}}}}
    return ss


def _parse_vless(link):
    u = urlparse(link); p = parse_qs(u.query)
    net = p.get("type", ["tcp"])[0]; sec = p.get("security", ["none"])[0]
    vnext = {"address": u.hostname, "port": u.port or 443,
             "users": [{"id": unquote(u.username or ""), "encryption": "none", "flow": p.get("flow", [""])[0]}]}
    return {"protocol": "vless", "settings": {"vnext": [vnext]}, "streamSettings": _stream(p, net, sec), "tag": "proxy"}


def _parse_vmess(link):
    raw = link[8:]; raw += "=" * (-len(raw) % 4)
    obj = json.loads(base64.b64decode(raw).decode())
    net = obj.get("net", "tcp"); sec = "tls" if obj.get("tls") in ("tls", True, "true") else "none"
    p = {"path": [obj.get("path", "/")], "host": [obj.get("host", "")],
         "sni": [obj.get("sni", obj.get("host", ""))], "serviceName": [obj.get("path", "")]}
    vnext = {"address": obj.get("add"), "port": int(obj.get("port", 443)),
             "users": [{"id": obj.get("id"), "alterId": int(obj.get("aid", 0)), "security": "auto"}]}
    return {"protocol": "vmess", "settings": {"vnext": [vnext]}, "streamSettings": _stream(p, net, sec), "tag": "proxy"}


def _parse_trojan(link):
    u = urlparse(link); p = parse_qs(u.query)
    net = p.get("type", ["tcp"])[0]; sec = p.get("security", ["tls"])[0]
    return {"protocol": "trojan", "settings": {"servers": [{"address": u.hostname, "port": u.port or 443,
            "password": unquote(u.username or "")}]}, "streamSettings": _stream(p, net, sec), "tag": "proxy"}


def _parse_ss(link):
    body = link[5:]
    if "#" in body: body = body.split("#", 1)[0]
    if "@" in body:
        ui, server = body.split("@", 1); ui += "=" * (-len(ui) % 4)
        try: method, password = base64.b64decode(ui).decode().split(":", 1)
        except Exception: method, password = unquote(ui).split(":", 1)
    else:
        body += "=" * (-len(body) % 4)
        creds, server = base64.b64decode(body).decode().split("@", 1)
        method, password = creds.split(":", 1)
    host, port = server.split(":"); port = int(port.split("/")[0].split("?")[0])
    return {"protocol": "shadowsocks", "settings": {"servers": [{"address": host, "port": port,
            "method": method, "password": password}]}, "tag": "proxy"}


def _parse_socks(link):
    u = urlparse(link)
    user = pwd = ""
    if u.username:
        # socks://base64(user:pass)@host:port  или  socks://user:pass@host:port
        if u.password is not None:
            user, pwd = unquote(u.username), unquote(u.password)
        else:
            try:
                dec = base64.b64decode(u.username + "=" * (-len(u.username) % 4)).decode()
                if ":" in dec: user, pwd = dec.split(":", 1)
            except Exception:
                user = unquote(u.username)
    server = {"address": u.hostname, "port": u.port or 1080}
    if user:
        server["users"] = [{"user": user, "pass": pwd}]
    return {"protocol": "socks", "settings": {"servers": [server]}, "tag": "proxy"}


def _parse_wireguard(link):
    u = urlparse(link); p = parse_qs(u.query)
    priv = unquote(u.username or "") or p.get("privatekey", p.get("secretkey", [""]))[0]
    pub = p.get("publickey", p.get("peerpublickey", p.get("pubkey", [""])))[0]
    addr = p.get("address", p.get("ip", ["10.0.0.2/32"]))[0]
    addrs = [a.split("/")[0] for a in addr.split(",") if a]
    out = {"protocol": "wireguard",
           "settings": {"secretKey": priv, "address": addrs or ["10.0.0.2"],
                        "peers": [{"publicKey": pub, "endpoint": f"{u.hostname}:{u.port or 51820}"}]},
           "tag": "proxy"}
    mtu = p.get("mtu", [""])[0]
    if mtu.isdigit(): out["settings"]["mtu"] = int(mtu)
    res = p.get("reserved", [""])[0]
    if res:
        try: out["settings"]["reserved"] = [int(x) for x in res.split(",") if x.strip().isdigit()]
        except Exception: pass
    return out


# Домены CDN-серверов загрузки Steam — их пускаем напрямую, чтобы игры
# качались на полной скорости, минуя VPN.
STEAM_DOMAINS = [
    "steamcontent.com", "steamstatic.com", "steamcdn-a.akamaihd.net",
    "steampipe.akamaized.net", "steamserver.net", "steamusercontent.com",
    "cs.steampowered.com", "dl.steam.clngaa.com", "st.dl.eccdnx.com",
    "st.dl.bscstorage.net", "steampipe.steamcontent.tnkjmec.com",
]


def _xray_routing(prefs):
    """Умная маршрутизация xray: локальные/RU и (опц.) Steam напрямую, остальное — VPN.
    Требует geoip.dat/geosite.dat рядом с ядром (XRAY_LOCATION_ASSET)."""
    prefs = prefs or {}
    rules = []
    if prefs.get("steam_direct"):
        rules.append({"type": "field", "outboundTag": "direct",
                      "domain": ["domain:" + d for d in STEAM_DOMAINS]})
    if prefs.get("route_smart"):
        rules.append({"type": "field", "ip": ["geoip:private", "geoip:ru"], "outboundTag": "direct"})
        rules.append({"type": "field", "domain": ["geosite:category-ru", "geosite:private"], "outboundTag": "direct"})
    if not rules:
        return None
    return {"domainStrategy": "IPIfNonMatch", "rules": rules}


def _singbox_route(prefs, final="proxy"):
    """Маршрутизация sing-box: приватные/RU и (опц.) Steam напрямую."""
    prefs = prefs or {}
    route = {"final": final}
    rules = []
    if prefs.get("steam_direct"):
        rules.append({"domain_suffix": STEAM_DOMAINS, "outbound": "direct"})
    if prefs.get("route_smart"):
        rules.append({"ip_is_private": True, "outbound": "direct"})
        rules.append({"rule_set": ["geoip-ru", "geosite-ru"], "outbound": "direct"})
        route["rule_set"] = [
            {"type": "remote", "tag": "geoip-ru", "format": "binary", "download_detour": "direct",
             "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs"},
            {"type": "remote", "tag": "geosite-ru", "format": "binary", "download_detour": "direct",
             "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-ru.srs"},
        ]
    if rules:
        route["rules"] = rules
    return route


def build_xray_config(outbound, prefs=None):
    prefs = prefs or {}
    # TLS-фрагментация (обход DPI): режем ClientHello и гоним прокси через
    # freedom-аутбаунд с fragment. Работает для vless/vmess/trojan/ss на ядре xray.
    if prefs.get("fragment"):
        import copy
        outbound = copy.deepcopy(outbound)               # не трогаем исходный outbound
        ss = outbound.setdefault("streamSettings", {})
        ss.setdefault("sockopt", {})["dialerProxy"] = "fragment"
        outbounds = [outbound, {"protocol": "freedom", "tag": "direct"},
                     {"tag": "fragment", "protocol": "freedom",
                      "settings": {"fragment": {"packets": "tlshello", "length": "100-200", "interval": "10-20"}}}]
    else:
        outbounds = [outbound, {"protocol": "freedom", "tag": "direct"}]
    listen = "0.0.0.0" if prefs.get("lan") else "127.0.0.1"   # «Разрешить LAN» → доступ из локальной сети
    cfg = {"log": {"loglevel": "warning"},
           "inbounds": [{"tag": "socks", "port": SOCKS_PORT, "listen": listen, "protocol": "socks", "settings": {"udp": True}},
                        {"tag": "http", "port": HTTP_PORT, "listen": listen, "protocol": "http"}],
           "outbounds": outbounds}
    r = _xray_routing(prefs)
    if r: cfg["routing"] = r
    return cfg


def build_singbox_config(outbound, prefs=None):
    """Конфиг sing-box: socks+http инбаунды на тех же портах, что и xray."""
    prefs = prefs or {}
    listen = "0.0.0.0" if prefs.get("lan") else "127.0.0.1"
    return {
        "log": {"level": "warn"},
        "inbounds": [
            {"type": "socks", "tag": "socks-in", "listen": listen, "listen_port": SOCKS_PORT},
            {"type": "http", "tag": "http-in", "listen": listen, "listen_port": HTTP_PORT},
        ],
        "outbounds": [outbound, {"type": "direct", "tag": "direct"}],
        "route": _singbox_route(prefs),
    }


def build_tun_config(prefs=None):
    """TUN-режим: sing-box перехватывает ВЕСЬ трафик системы и гонит его в наш
    локальный socks-прокси (xray/sing-box). Требует прав администратора."""
    return {
        "log": {"level": "warn"},
        "inbounds": [{
            "type": "tun", "tag": "tun-in", "interface_name": "zyng",
            "address": ["172.19.0.1/30"], "mtu": 1500,
            "auto_route": True, "strict_route": True, "stack": "system",
        }],
        "outbounds": [
            {"type": "socks", "tag": "proxy", "server": "127.0.0.1", "server_port": SOCKS_PORT, "version": "5"},
            {"type": "direct", "tag": "direct"},
        ],
        "route": _singbox_route(prefs),
    }


# ══ СИСТЕМНЫЙ ПРОКСИ ═════════════════════════════════════════════════════════
def set_system_proxy(enable):
    if sys.platform == "darwin": _set_mac_proxy(enable); return
    if os.name != "nt": _set_linux_proxy(enable); return
    import winreg, ctypes
    key = winreg.OpenKey(winreg.HKEY_CURRENT_USER,
        r"Software\Microsoft\Windows\CurrentVersion\Internet Settings", 0, winreg.KEY_ALL_ACCESS)
    if enable:
        winreg.SetValueEx(key, "ProxyEnable", 0, winreg.REG_DWORD, 1)
        winreg.SetValueEx(key, "ProxyServer", 0, winreg.REG_SZ, f"127.0.0.1:{HTTP_PORT}")
        winreg.SetValueEx(key, "ProxyOverride", 0, winreg.REG_SZ, "localhost;127.*;10.*;172.16.*;192.168.*;<local>")
    else:
        winreg.SetValueEx(key, "ProxyEnable", 0, winreg.REG_DWORD, 0)
    winreg.CloseKey(key)
    inet = ctypes.windll.Wininet; inet.InternetSetOptionW(0, 39, 0, 0); inet.InternetSetOptionW(0, 37, 0, 0)


def _set_mac_proxy(enable):
    def services():
        try:
            out = subprocess.check_output(["networksetup", "-listallnetworkservices"]).decode()
            return [s.strip() for s in out.splitlines()[1:] if s.strip() and not s.startswith("*")]
        except Exception:
            return ["Wi-Fi"]
    for svc in services():
        try:
            if enable:
                subprocess.run(["networksetup", "-setwebproxy", svc, "127.0.0.1", str(HTTP_PORT)], check=False)
                subprocess.run(["networksetup", "-setsecurewebproxy", svc, "127.0.0.1", str(HTTP_PORT)], check=False)
                subprocess.run(["networksetup", "-setsocksfirewallproxy", svc, "127.0.0.1", str(SOCKS_PORT)], check=False)
            else:
                for m in ("-setwebproxystate", "-setsecurewebproxystate", "-setsocksfirewallproxystate"):
                    subprocess.run(["networksetup", m, svc, "off"], check=False)
        except Exception:
            pass


def _set_linux_proxy(enable):
    def g(*a):
        try: subprocess.run(["gsettings"] + list(a), check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception: pass
    if enable:
        g("set", "org.gnome.system.proxy", "mode", "manual")
        for pr in ("http", "https"):
            g("set", f"org.gnome.system.proxy.{pr}", "host", "127.0.0.1")
            g("set", f"org.gnome.system.proxy.{pr}", "port", str(HTTP_PORT))
        g("set", "org.gnome.system.proxy.socks", "host", "127.0.0.1")
        g("set", "org.gnome.system.proxy.socks", "port", str(SOCKS_PORT))
    else:
        g("set", "org.gnome.system.proxy", "mode", "none")


def _linux_autostart_path():
    d = os.path.join(os.path.expanduser("~"), ".config", "autostart")
    return os.path.join(d, "zyng.desktop")


def set_autostart(enable):
    if not getattr(sys, "frozen", False): return
    if os.name == "nt":
        import winreg
        key = winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run", 0, winreg.KEY_ALL_ACCESS)
        if enable: winreg.SetValueEx(key, "Zyng", 0, winreg.REG_SZ, f'"{sys.executable}"')
        else:
            try: winreg.DeleteValue(key, "Zyng")
            except Exception: pass
        winreg.CloseKey(key)
    elif sys.platform != "darwin":
        # Linux: файл .desktop в ~/.config/autostart
        path = _linux_autostart_path()
        try:
            if enable:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as f:
                    f.write("[Desktop Entry]\nType=Application\nName=Zyng VPN\n"
                            f"Exec=\"{sys.executable}\"\nX-GNOME-Autostart-enabled=true\nTerminal=false\n")
            elif os.path.exists(path):
                os.remove(path)
        except Exception:
            pass


def get_autostart():
    if os.name == "nt":
        try:
            import winreg
            k = winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run")
            winreg.QueryValueEx(k, "Zyng"); winreg.CloseKey(k); return True
        except Exception:
            return False
    if sys.platform != "darwin":
        return os.path.exists(_linux_autostart_path())
    return False


# Многие панели по User-Agent решают, какой формат отдать. С незнакомым UA
# отдают заглушку «App not supported». Перебираем UA известных клиентов.
SUB_USER_AGENTS = [
    # Строка полная, с версией и платформой: панели, которые сверяют
    # User-Agent строго, огрызок «Happ/1.0» не узнают и отдают 404.
    "Happ/1.16.0 (Windows)",
    "v2rayNG/1.9.5",
    "v2rayN/6.45",
    "Streisand",
    "sing-box/1.9.0",
    "SFA/1.9.0",
    "SFI/1.9.0",
    "clash-verge/1.6.0",
    "clash.meta/1.18.0",
    "NekoBox/1.3.0",
    "hiddify-next/2.0.0",
    "Shadowrocket/2.2.0",
    "ktor-client",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
]


def _norm_sub_url(url):
    """Outline: ssconf://host/path — это на самом деле https://host/path (SIP008)."""
    u = (url or "").strip()
    if u.startswith("ssconf://"):
        return "https://" + u[len("ssconf://"):]
    return u


def _hwid():
    """Стабильный идентификатор устройства (HWID). Панели с лимитом устройств
    (Remnawave/Happ-совместимые) требуют его, иначе отдают заглушку вместо серверов."""
    path = os.path.join(os.path.dirname(CONFIG_FILE), ".zyng_hwid")
    try:
        with open(path, encoding="utf-8") as f:
            h = f.read().strip()
            if h:
                return h
    except Exception:
        pass
    import uuid
    h = str(uuid.uuid4())
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(h)
    except Exception:
        pass
    return h


def _sub_headers(ua):
    """Заголовки запроса подписки, включая HWID (как шлёт Happ)."""
    osname = "Windows" if os.name == "nt" else ("macOS" if sys.platform == "darwin" else "Linux")
    try:
        import platform as _pf; osver = _pf.release()
    except Exception:
        osver = ""
    return {
        "User-Agent": ua, "Accept": "*/*",
        "x-hwid": _hwid(),
        "x-device-os": osname,
        "x-ver-os": osver,
        "x-device-model": "Zyng " + APP_VERSION,
    }


# Ключ где угодно в тексте: перед ним начало строки, пробел, кавычка или
# скобка, а заканчивается он на первом символе, который в ссылке не встречается.
_LINK_RE = re.compile(
    r'(?<![A-Za-z0-9/:._-])'
    r'(?:vless|vmess|trojan|ss|socks5?|wireguard|wg|hysteria2?|hy2|tuic)://'
    r'[^\s"\'<>\\\]\},]+'
)


def _fetch_sub_once(url, ua, ctx):
    url = _norm_sub_url(url)
    req = urllib.request.Request(url, headers=_sub_headers(ua))
    with urllib.request.urlopen(req, timeout=8, context=ctx) as r:
        raw = r.read().decode("utf-8", "ignore").strip()
        title = r.headers.get("Profile-Title", "")
        userinfo = r.headers.get("Subscription-Userinfo", "")
    # варианты: как есть и base64-декод
    candidates = [raw]
    try:
        dec = base64.b64decode(raw + "=" * (-len(raw) % 4)).decode("utf-8", "ignore")
        candidates.append(dec)
    except Exception:
        pass
    # 1) JSON-подписка (готовый xray/sing-box конфиг, как у incy/K-VPN)
    for c in candidates:
        js = _extract_json_servers(c.strip().lstrip("﻿"))
        if js:
            return js, title, userinfo
    # 2) Clash / Clash.Meta YAML-подписка (proxies:) → через ядро sing-box
    for c in candidates:
        cl = _extract_clash_servers(c.strip().lstrip("﻿"))
        if cl:
            return cl, title, userinfo
    # 3) обычные ссылки — ТОЛЬКО настоящие протоколы (не http/https/мусор из JSON)
    VALID = ("vless://", "vmess://", "trojan://", "ss://", "socks://", "socks5://",
             "wireguard://", "wg://", "hysteria2://", "hy2://", "hysteria://", "tuic://")
    def _is_stub(l):
        low = unquote(l).lower()
        return ("app not supported" in low) or ("not supported" in low) or ("unsupported" in low)
    links = []
    for c in candidates:
        for ln in c.splitlines():
            ln = ln.strip()
            if ln.startswith(VALID) and not _is_stub(ln) and ln not in links:
                links.append(ln)

    # 4) Последняя попытка: ищем ключи по всему телу ответа.
    #
    # Выше строка засчитывалась, только если начиналась с протокола. Но часть
    # панелей вместо голого списка отдаёт свою HTML-страницу, а ключи лежат
    # внутри неё — в JavaScript, в JSON или в атрибуте кнопки «скопировать».
    # Тогда ни одна строка с протокола не начинается, и подписка выглядела
    # пустой при живом ответе.
    if not links:
        for c in candidates:
            text = c.replace("&amp;", "&").replace("\\/", "/")
            for m in _LINK_RE.finditer(text):
                ln = m.group(0).rstrip(".,;")
                if not _is_stub(ln) and ln not in links:
                    links.append(ln)

    return links, title, userinfo


def _sub_url_variants(url):
    """Адреса, по которым панели отдают конфиг.

    Часть панелей на голый адрес подписки показывает HTML-страницу или отвечает
    404, а сам конфиг лежит рядом — под суффиксом клиента или за параметром
    format. Единого стандарта нет, поэтому пробуем известные варианты по
    очереди. Ответ принимается только если в нём действительно есть ключи, так
    что неудачная догадка ничего не портит.
    """
    base = _norm_sub_url(url).rstrip("/")
    sep = "&" if "?" in base else "?"
    out = [base]
    for suffix in ("/v2ray", "/v2ray-json", "/sing-box", "/singbox", "/clash", "/clash-meta"):
        out.append(base + suffix)
    for fmt in ("v2ray", "v2ray-json", "sing-box", "clash"):
        out.append(f"{base}{sep}format={fmt}")
    return out


def fetch_subscription(url):
    """Возвращает (список_ключей, инфо_подписки). Перебирает User-Agent'ы,
    пока панель не отдаст настоящие серверы (а не «App not supported»)."""
    ctx = None
    try:
        import ssl
        ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    except Exception:
        pass
    last_err = None
    best = ([], "", "")
    for ua in SUB_USER_AGENTS:
        try:
            links, title, userinfo = _fetch_sub_once(url, ua, ctx)
            if links:
                return links, _parse_userinfo(userinfo, title)
            # запомним хоть какой-то ответ (для инфо), но продолжим искать серверы
            if title or userinfo:
                best = (links, title, userinfo)
        except Exception as e:
            last_err = e

    # Ни один User-Agent не помог. Значит дело может быть не в клиенте, а в
    # адресе: пробуем те же запросы по соседним путям, которыми панели отдают
    # конфиг. Берём только два-три агента, иначе перебор растянется надолго.
    for alt in _sub_url_variants(url)[1:]:
        for ua in SUB_USER_AGENTS[:3]:
            try:
                links, title, userinfo = _fetch_sub_once(alt, ua, ctx)
                if links:
                    return links, _parse_userinfo(userinfo, title)
                if (title or userinfo) and not (best[1] or best[2]):
                    best = (links, title, userinfo)
            except Exception:
                pass

    if best[1] or best[2]:
        return best[0], _parse_userinfo(best[2], best[1])
    if last_err:
        raise last_err
    return [], _parse_userinfo("", "")


def _decode_title(title):
    """Некоторые панели отдают Profile-Title в base64 (с префиксом 'base64:')."""
    t = (title or "").strip()
    if t.lower().startswith("base64:"):
        t = t.split(":", 1)[1]
    try:
        dec = base64.b64decode(t + "=" * (-len(t) % 4)).decode("utf-8")
        if dec.isprintable() or any(ord(c) > 127 for c in dec):
            return dec.strip()
    except Exception:
        pass
    return (title or "").strip()


def _parse_userinfo(userinfo, title):
    """Разбирает 'upload=..; download=..; total=..; expire=..' в понятный вид."""
    d = {"title": _decode_title(title) or "Zyng VPN"}
    parts = {}
    for kv in userinfo.replace(",", ";").split(";"):
        if "=" in kv:
            k, v = kv.split("=", 1)
            try: parts[k.strip()] = int(v.strip())
            except Exception: pass
    used = parts.get("upload", 0) + parts.get("download", 0)
    total = parts.get("total", 0)
    exp = parts.get("expire", 0)
    def gb(b): return b / (1024**3)
    if total:
        d["traffic"] = f"{gb(used):.1f} / {gb(total):.0f} ГБ"
        d["left_gb"] = f"осталось {gb(total-used):.1f} ГБ"
    elif used:
        d["traffic"] = f"{gb(used):.1f} ГБ / ∞"
        d["left_gb"] = "безлимит"
    else:
        d["traffic"] = "∞"
        d["left_gb"] = "безлимит"
    if exp:
        days = int((exp - time.time()) / 86400)
        d["expire"] = f"осталось {days} дн." if days >= 0 else "истекла"
    else:
        d["expire"] = "бессрочно"
    return d


def _sub_title(url):
    try:
        h = urlparse(url).hostname or url
        return h.replace("www.", "")[:22]
    except Exception:
        return "Подписка"


def _port_open(host, port, timeout=0.4):
    """Слушает ли кто-нибудь этот порт. Так проверяем, что ядро поднялось."""
    try:
        c = socket.create_connection((host, int(port)), timeout=timeout)
        c.close()
        return True
    except Exception:
        return False


def _last_core_error(path, limit=240):
    """Внятная строка из журнала ядра — для показа человеку.

    Ядра пишут много служебного, а важна обычно последняя содержательная
    строка. Если журнала нет вовсе, честно так и говорим, а не молчим.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = [l.strip() for l in f if l.strip()]
    except Exception:
        lines = []
    if not lines:
        return tr("причина неизвестна", "reason unknown")
    for line in reversed(lines):
        low = line.lower()
        if "error" in low or "failed" in low or "invalid" in low or "panic" in low:
            return line[-limit:]
    return lines[-1][-limit:]


def _proxy_works(socks_port, timeout=8.0):
    """Идёт ли трафик через локальный SOCKS. Возвращает (успех, причина).

    Через SOCKS, а не через системный прокси: системный ещё может быть не
    подхвачен приложениями, а нам нужно проверить именно ядро.
    """
    try:
        import socket as _s
        c = _s.create_connection(("127.0.0.1", int(socks_port)), timeout=3)
        c.settimeout(timeout)
        # SOCKS5: приветствие без авторизации.
        c.sendall(b"\x05\x01\x00")
        if c.recv(2) != b"\x05\x00":
            c.close()
            return False, tr("прокси не отвечает", "the proxy does not answer")
        # CONNECT к cp.cloudflare.com:80 по имени — заодно проверяем DNS сервера.
        host = b"cp.cloudflare.com"
        c.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + (80).to_bytes(2, "big"))
        rep = c.recv(4)
        if len(rep) < 2 or rep[1] != 0x00:
            c.close()
            codes = {1: "общий сбой", 2: "запрещено", 3: "сеть недоступна",
                     4: "хост недоступен", 5: "соединение отклонено",
                     6: "истекло время", 7: "команда не поддержана"}
            code = rep[1] if len(rep) > 1 else -1
            return False, tr(f"сервер ответил «{codes.get(code, code)}»",
                             f"the server replied with error {code}")
        # Дочитываем адрес в ответе и шлём настоящий запрос.
        c.recv(256)
        c.sendall(b"GET /generate_204 HTTP/1.1\r\nHost: cp.cloudflare.com\r\n"
                  b"Connection: close\r\n\r\n")
        data = c.recv(64)
        c.close()
        if data.startswith(b"HTTP/"):
            return True, ""
        return False, tr("ответ не получен", "no answer received")
    except Exception as e:
        return False, str(e)[:120] or tr("нет связи", "no connection")


def tcp_ping(host, port, timeout=4.0):
    """Лучший из 2 замеров TCP-хендшейка. Домены резолвим заранее (система может
    блокировать DNS — тогда пробуем как есть)."""
    best = None
    for _ in range(2):
        try:
            s = time.time()
            c = socket.create_connection((host, port), timeout=timeout); c.close()
            ms = int((time.time() - s) * 1000)
            if best is None or ms < best:
                best = ms
        except Exception:
            pass
    return best


# красивый системный шрифт под каждую ОС
if os.name == "nt":
    FONT = "Segoe UI"
elif sys.platform == "darwin":
    FONT = "SF Pro Display"
else:
    FONT = "DejaVu Sans"


def _register_custom_font():
    """Подключает встроенный современный шрифт Inter. Если не вышло — остаётся
    системный (Segoe UI и т.п.), интерфейс не ломается."""
    global FONT
    try:
        p = resource_path("Inter.ttf")
        if not os.path.exists(p):
            return
        if os.name == "nt":
            import ctypes
            FR_PRIVATE = 0x10
            if ctypes.windll.gdi32.AddFontResourceExW(ctypes.c_wchar_p(p), FR_PRIVATE, 0):
                FONT = "Inter"
        else:
            # Linux/mac: копируем в пользовательские шрифты и обновляем кеш
            import shutil
            dst_dir = os.path.join(os.path.expanduser("~"), ".fonts")
            os.makedirs(dst_dir, exist_ok=True)
            dst = os.path.join(dst_dir, "Inter.ttf")
            if not os.path.exists(dst):
                shutil.copyfile(p, dst)
                try: subprocess.run(["fc-cache", "-f", dst_dir], check=False,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except Exception: pass
            FONT = "Inter"
    except Exception:
        pass


_register_custom_font()



# ══ ВИДЖЕТЫ В СТИЛЕ ZYNG ═════════════════════════════════════════════════════
#
# CustomTkinter не умеет градиенты и капсулы с обводкой, поэтому рисуем их
# сами на Canvas — ровно так, как выглядит мобильная версия.

class GradientButton(tk.Canvas):
    """Кнопка с горизонтальным градиентом от акцента к фиолетовому."""

    def __init__(self, master, text, command, height=46, **kw):
        super().__init__(master, height=height, highlightthickness=0, bd=0,
                         bg=BG, cursor="hand2", **kw)
        self._text = text
        self._command = command
        self._h = height
        self.bind("<Configure>", lambda e: self._render())
        self.bind("<Button-1>", lambda e: self._command())

    def _render(self):
        self.delete("all")
        w, h = self.winfo_width(), self._h
        if w < 2:
            return
        r = h // 2
        a = tuple(int(ACC[i:i + 2], 16) for i in (1, 3, 5))
        b = tuple(int(ACC2[i:i + 2], 16) for i in (1, 3, 5))

        # Градиент рисуем вертикальными полосками — в Tkinter градиентной
        # заливки нет вовсе. Высоту каждой полоски берём по окружности, так
        # скругление получается само собой, без закрашивания углов.
        for x in range(w):
            t = x / (w - 1)
            col = "#%02x%02x%02x" % tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
            if x < r:
                dy = r - int((r * r - (r - x) ** 2) ** 0.5)
            elif x > w - r:
                dy = r - int((r * r - (x - (w - r)) ** 2) ** 0.5)
            else:
                dy = 0
            self.create_line(x, dy, x, h - dy, fill=col)

        self.create_text(w // 2, h // 2, text=self._text, fill="#ffffff",
                         font=(FONT, 13, "bold"))


class _PillLabel:
    """Статус в виде капсулы с точкой — как pill на главном экране Zyng."""

    def __init__(self, canvas, app):
        self.cv = canvas
        self.app = app
        self._text = ""
        self._color = MUTED

    def configure(self, text=None, text_color=None):
        if text is not None:
            self._text = text
        if text_color is not None:
            self._color = text_color
        self._render()

    # Совместимость с CTkLabel: остальной код зовёт .configure(...)
    config = configure

    def _render(self):
        cv = self.cv
        cv.delete("all")
        w = int(cv["width"]); h = int(cv["height"])
        r = h // 2
        # Капсула: два круга и прямоугольник между ними.
        cv.create_oval(0, 0, h, h, fill=CARD, outline=BORDER)
        cv.create_oval(w - h, 0, w, h, fill=CARD, outline=BORDER)
        cv.create_rectangle(r, 0, w - r, h, fill=CARD, outline="")
        cv.create_line(r, 0, w - r, 0, fill=BORDER)
        cv.create_line(r, h - 1, w - r, h - 1, fill=BORDER)
        # Точка состояния и подпись.
        cv.create_oval(18, r - 5, 28, r + 5, fill=self._color, outline="")
        cv.create_text(w // 2 + 8, r, text=self._text, fill=self._color,
                       font=(FONT, 13, "bold"))


# ══ ПРИЛОЖЕНИЕ ═══════════════════════════════════════════════════════════════
class ZyngApp:
    def __init__(self, root):
        self.root = root
        self.proc = None
        self.connected = False
        self.links = []            # текущий отображаемый список (по активной вкладке)
        self.manual_links = []     # ключи, добавленные вручную
        self.subs = []             # [{"url","title"}] — несколько подписок
        self.sub_cache = {}        # url -> {"links":[...], "info":{...}}
        self.active_tab = "all"    # "all" | "manual" | url подписки
        self.sub_url = ""          # совместимость (последняя подписка)
        self.autoconnect = False
        self.prefs = {}
        self.selected_idx = 0
        self.sub_info = {}
        self._flag_cache = {}
        self.pings = {}
        self._ping_lbls = {}

        root.title(APP_NAME); root.geometry("880x600"); root.minsize(820, 560)
        try:
            if os.name == "nt":
                ico = resource_path("icon.ico")
                if os.path.exists(ico): root.iconbitmap(ico)
        except Exception:
            pass

        # Раскладка как в мобильном Zyng: слева список серверов, справа — экран
        # подключения с большой круглой кнопкой, статусом, таймером и задержкой.
        root.configure(fg_color=BG)
        root.grid_columnconfigure(0, weight=5, uniform="main")
        root.grid_columnconfigure(1, weight=4, uniform="main")
        root.grid_rowconfigure(0, weight=1)

        # ══ ЛЕВАЯ КОЛОНКА: СЕРВЕРЫ ═══════════════════════════════════════════
        mid = ctk.CTkFrame(root, fg_color=BG, corner_radius=0)
        mid.grid(row=0, column=0, sticky="nsew")
        mid.grid_rowconfigure(2, weight=1); mid.grid_columnconfigure(0, weight=1)

        head = ctk.CTkFrame(mid, fg_color="transparent")
        head.grid(row=0, column=0, sticky="ew", padx=20, pady=(20, 4))
        ctk.CTkLabel(head, text=tr("Серверы", "Servers"),
                     font=ctk.CTkFont(FONT, 20, "bold"), text_color=TEXT).pack(side="left")
        for label, cmd, tip in (("⚙", self.open_settings, None),
                                ("🔄", self.update_sub, None),
                                ("📶", self.do_ping, None)):
            ctk.CTkButton(head, text=label, width=34, height=34, corner_radius=17,
                          fg_color=CARD, hover_color=CARD2, text_color=ACC,
                          border_width=1, border_color=BORDER,
                          font=ctk.CTkFont(FONT, 15),
                          command=cmd).pack(side="right", padx=(6, 0))

        srow = ctk.CTkFrame(mid, fg_color="transparent")
        srow.grid(row=1, column=0, sticky="ew", padx=20, pady=(8, 6))
        self.tabs_frame = srow
        self._tab_map = {}
        self.tab_menu = ctk.CTkOptionMenu(srow, values=["Все"], height=38,
                                          corner_radius=19, fg_color=CARD, button_color=CARD2,
                                          button_hover_color=BORDER, text_color=TEXT,
                                          dropdown_fg_color=CARD, dropdown_text_color=TEXT,
                                          dropdown_hover_color=CARD2,
                                          font=ctk.CTkFont(FONT, 13, "bold"),
                                          command=self._on_tab_menu)
        self.tab_menu.pack(side="left", fill="x", expand=True)
        ctk.CTkButton(srow, text=tr("⚡ Авто", "⚡ Auto"), width=84, height=38, corner_radius=19,
                      fg_color=CARD, hover_color=CARD2, text_color=ACC,
                      border_width=1, border_color=BORDER,
                      font=ctk.CTkFont(FONT, 13, "bold"),
                      command=self.connect_fastest).pack(side="left", padx=(8, 0))

        self.server_list = ctk.CTkScrollableFrame(mid, fg_color="transparent",
                                                  scrollbar_button_color=CARD2,
                                                  scrollbar_button_hover_color=BORDER)
        self.server_list.grid(row=2, column=0, sticky="nsew", padx=14, pady=(4, 6))
        self.empty_lbl = None

        brow = ctk.CTkFrame(mid, fg_color="transparent")
        brow.grid(row=3, column=0, sticky="ew", padx=20, pady=(2, 18))
        self.add_btn = GradientButton(
            brow, text=tr("＋  Добавить ключ / подписку", "＋  Add key / subscription"),
            command=self.paste_key, height=46)
        self.add_btn.pack(fill="x")

        # ══ ПРАВАЯ КОЛОНКА: ПОДКЛЮЧЕНИЕ ══════════════════════════════════════
        right = ctk.CTkFrame(root, fg_color=BG, corner_radius=0)
        right.grid(row=0, column=1, sticky="nsew")
        right.grid_columnconfigure(0, weight=1)
        right.grid_rowconfigure(1, weight=1)   # воздух над кнопкой
        right.grid_rowconfigure(6, weight=1)   # воздух между группами

        # Шапка: логотип и название — единственное, что осталось от прежнего вида.
        h = ctk.CTkFrame(right, fg_color="transparent")
        h.grid(row=0, column=0, pady=(24, 0))
        self._logo_ref = None
        try:
            from PIL import Image
            lp = resource_path("logo_white.png")
            if os.path.exists(lp):
                im = Image.open(lp).convert("RGBA"); ratio = im.width / im.height

                # Перекрашиваем ТОЛЬКО силуэт с прозрачным фоном.
                #
                # Перекраска выбрасывает цвета и оставляет один альфа-канал.
                # Для силуэта это ровно то, что нужно, а для непрозрачной
                # картинки — катастрофа: альфа у неё везде 255, и на месте
                # логотипа появляется сплошной прямоугольник цвета текста.
                # Именно это и случилось, когда сюда подложили значок
                # приложения вместо метки. Считаем долю непрозрачного и, если
                # картинка сплошная, показываем её как есть.
                alpha = im.getchannel("A")
                solid = sum(1 for v in alpha.getdata() if v > 250)
                is_silhouette = solid < im.width * im.height * 0.9

                if is_silhouette and TEXT.upper() != "#FFFFFF":
                    r, g, b = (int(TEXT[i:i + 2], 16) for i in (1, 3, 5))
                    tint = Image.new("RGBA", im.size, (r, g, b, 0))
                    tint.putalpha(im.getchannel("A"))
                    im = tint
                H = 48
                img = ctk.CTkImage(im, size=(int(H * ratio * 1.08), H))
                ctk.CTkLabel(h, image=img, text="").pack()
                self._logo_ref = img
        except Exception:
            pass
        if self._logo_ref is None:
            ctk.CTkLabel(h, text="Zyng", font=ctk.CTkFont(FONT, 22, "bold"),
                         text_color=TEXT).pack()

        # Тумблер — тот же, что был до 6.0. Круглая кнопка со сферой в Tkinter
        # получилась плохо: символ питания ⏻ в системных шрифтах Windows
        # отсутствует и разъезжается, а дуги без сглаживания выглядят рваными.
        # Крупнее прежнего. Это главный орган управления на экране, а он был
        # одного роста с подписью под ним и терялся в пустоте правой колонки.
        self.toggle_w, self.toggle_h = 170, 80
        self._tgl_pos = 0.0
        self.toggle_cv = tk.Canvas(right, width=self.toggle_w, height=self.toggle_h,
                                   bg=BG, highlightthickness=0, bd=0, cursor="hand2")
        self.toggle_cv.grid(row=2, column=0, pady=(4, 0))
        self.toggle_cv.bind("<Button-1>", lambda e: self.toggle())
        self._draw_toggle()

        # Статус-пилюля
        self.status_cv = tk.Canvas(right, width=208, height=38, bg=BG,
                                   highlightthickness=0, bd=0)
        self.status_cv.grid(row=3, column=0, pady=(14, 0))
        self.status = _PillLabel(self.status_cv, self)
        self.status.configure(text=tr("Отключено", "Disconnected"), text_color=MUTED)

        # Крупно и моноширинным.
        #
        # Пока туннель поднят, это единственная живая цифра на экране, а
        # шестнадцатым кеглем она читалась как служебная строчка. Моноширинный
        # шрифт здесь обязателен: у пропорционального цифры разной ширины, и
        # строка дёргалась бы каждую секунду.
        self.timer_lbl = ctk.CTkLabel(right, text="00:00:00", text_color=MUTED,
                                      font=ctk.CTkFont("Consolas" if os.name == "nt" else "monospace",
                                                       27, "bold"))
        self.timer_lbl.grid(row=4, column=0, pady=(12, 0))

        self.ping_lbl = ctk.CTkLabel(right, text="", font=ctk.CTkFont(FONT, 13, "bold"),
                                     text_color=MUTED)
        self.ping_lbl.grid(row=5, column=0, pady=(4, 0))

        # Карточка выбранного сервера — открывает список слева.
        #
        # Над ней подпись: без неё карточка читалась как обычная надпись и было
        # неочевидно, что это выбор сервера. Ровно та же правка, что и в
        # версии для iPhone, — приложения должны вести себя одинаково.
        ctk.CTkLabel(right, text=tr("СЕРВЕР", "SERVER"),
                     font=ctk.CTkFont(FONT, 10, "bold"), text_color=MUTED,
                     anchor="w").grid(row=7, column=0, sticky="w", padx=26, pady=(0, 4))

        card = ctk.CTkFrame(right, fg_color=CARD, corner_radius=18,
                            border_width=1, border_color=BORDER)
        card.grid(row=8, column=0, sticky="ew", padx=22, pady=(0, 0))
        inner = ctk.CTkFrame(card, fg_color="transparent")
        inner.pack(fill="x", padx=14, pady=12)
        self.cur_flag = tk.Label(inner, bg=CARD)
        self.cur_flag.pack(side="left", padx=(0, 12))
        txt = ctk.CTkFrame(inner, fg_color="transparent"); txt.pack(side="left", fill="x", expand=True)
        self.cur_lbl = ctk.CTkLabel(txt, text=tr("Сервер не выбран", "No server selected"),
                                    font=ctk.CTkFont(FONT, 14, "bold"),
                                    text_color=TEXT, anchor="w")
        self.cur_lbl.pack(anchor="w")
        self.cur_sub_lbl = ctk.CTkLabel(txt, text=tr("Добавь ключ или подписку",
                                                     "Add a key or subscription"),
                                        font=ctk.CTkFont(FONT, 11), text_color=MUTED, anchor="w")
        self.cur_sub_lbl.pack(anchor="w")

        # Кнопка замера скорости — под карточкой, чтобы не спорить с главной.
        ctk.CTkButton(right, text=tr("⚡ Проверить скорость", "⚡ Test speed"),
                      height=36, corner_radius=18,
                      fg_color=CARD, hover_color=CARD2, text_color=ACC,
                      border_width=1, border_color=BORDER,
                      font=ctk.CTkFont(FONT, 12, "bold"),
                      command=self.speed_test).grid(row=9, column=0, sticky="ew",
                                                    padx=22, pady=(12, 4))

        # Без номера версии.
        #
        # Постоянно висящая версия человеку ничего не даёт: она интересна ровно
        # в один момент — когда вышла новая. Тогда её и покажем, в плашке
        # обновления внизу окна.
        foot = ctk.CTkLabel(right, text="t.me/zyngfast",
                            font=ctk.CTkFont(FONT, 10, "bold"), text_color=MUTED, cursor="hand2")
        foot.grid(row=10, column=0, pady=(2, 16))
        foot.bind("<Button-1>", lambda e: self._open_tg())
        self._connect_time = None

        # плашка обновления (поверх, сверху по центру)
        self.update_bar = None

        self.load_saved()
        # применяем сохранённую тему
        _t = self.prefs.get("theme", "Тёмная")
        ctk.set_appearance_mode({"Светлая": "light", "Тёмная": "dark", "Системная": "system"}.get(_t, "dark"))
        self.render_servers()

        # Показываем выбранный сервер сразу при запуске.
        #
        # Раньше правая колонка обновлялась только при подключении или ручном
        # выборе, а до этого держала заготовку «Сервер не выбран». Получалось
        # противоречие: слева у сервера стоит галочка, справа написано, что не
        # выбран ничего. Выбор при этом был настоящий — не показывали его.
        self._restore_current_label()

        self.check_update()
        if self.links:
            self.root.after(400, self.do_ping)
        if self.autoconnect and self.links:
            self.root.after(800, self.connect)
        root.protocol("WM_DELETE_WINDOW", self.on_close)

    # ── Добавление ключа/подписки ──
    def _add_manual(self, keys):
        existing = set(self.manual_links)
        # принимаем только настоящие ключи, http(s)-ссылки сюда не попадают
        ok = ("vless://", "vmess://", "trojan://", "ss://", "socks://", "socks5://",
              "wireguard://", "wg://", "hysteria2://", "hy2://", "hysteria://", "tuic://")
        added = [k for k in keys if k.startswith(ok + ("sb://",)) and k not in existing]
        self.manual_links += added
        self.active_tab = "all"
        self.selected_idx = 0
        self._rebuild_links(); self.render_servers(); self.save(silent=True); self.do_ping()
        return len(added)

    def add_key(self):
        dlg = ctk.CTkInputDialog(text=tr("Вставь ключ (vless/vmess/trojan/ss) или ссылку-подписку:",
                                         "Paste a key (vless/vmess/trojan/ss) or a subscription link:"),
                                 title=tr("Добавить", "Add"))
        v = (dlg.get_input() or "").strip()
        if not v:
            return
        # ссылка-подписка → отдельным разделом, а не как «битый ключ»
        # (ssconf:// — динамический ключ Outline, тоже подписка)
        if v.startswith(("http://", "https://", "ssconf://")):
            self._add_sub_url(v); return
        if "://" in v:
            n = self._add_manual([v])
            self._flash(tr(f"Добавлено: {n}", f"Added: {n}") if n
                        else tr("Такой ключ уже есть", "That key is already added"), OK if n else WARN)
        else:
            self._flash(tr("Не похоже на ключ или ссылку", "That is not a key or a link"), DANGER)

    def paste_key(self):
        try: data = self.root.clipboard_get()
        except Exception: self._flash(tr("Буфер пуст", "Clipboard is empty"), DANGER); return
        lines = [l.strip() for l in data.splitlines() if "://" in l and not l.strip().startswith("http")]
        subs = [l.strip() for l in data.splitlines() if l.strip().startswith("http")]
        if subs:
            self._add_sub_url(subs[0]); return
        if not lines:
            self._flash(tr("В буфере нет ключа", "No key in the clipboard"), DANGER); return
        n = self._add_manual(lines)
        self._flash(tr(f"Добавлено серверов: {n}", f"Servers added: {n}"), OK)

    def add_sub(self):
        dlg = ctk.CTkInputDialog(text=tr("Вставь ссылку-подписку (https://…):",
                                         "Paste a subscription link (https://…):"),
                                 title=tr("Подписка", "Subscription"))
        v = dlg.get_input()
        if v and v.startswith("http"):
            self._add_sub_url(v.strip())

    def _add_sub_url(self, url):
        if any(s["url"] == url for s in self.subs):
            self._flash(tr("Подписка уже добавлена", "Subscription already added"), WARN)
        else:
            self.subs.append({"url": url, "title": _sub_title(url)})
        self.sub_url = url
        self.active_tab = url
        self.render_tabs()
        self._flash(tr("Загружаю подписку…", "Loading subscription…"), MUTED)
        # ЗАГРУЗКА В ФОНЕ — интерфейс не зависает
        def worker():
            try:
                links, info = fetch_subscription(url)
                if len(links) > MAX_SERVERS:               # защита от зависания
                    links = links[:MAX_SERVERS]
                def done():
                    self.sub_cache[url] = {"links": links, "info": info}
                    for s in self.subs:
                        if s["url"] == url and info.get("title"):
                            s["title"] = info["title"]
                    self.selected_idx = 0
                    self._rebuild_links(); self.render_servers(); self.save(silent=True); self.do_ping()
                    self._flash(tr(f"Серверов: {len(links)} ✓", f"Servers: {len(links)} ✓") if links
                                else tr("Подписка пустая", "Subscription is empty"),
                                OK if links else WARN)
                self.root.after(0, done)
            except Exception as e:
                self.root.after(0, lambda: self._flash(self._friendly_err(e), WARN))
        threading.Thread(target=worker, daemon=True).start()

    def _open_tg(self):
        try:
            import webbrowser; webbrowser.open(TELEGRAM_URL)
        except Exception:
            pass

    def _notify(self, title, msg):
        """Системное уведомление у часов (Windows toast / Linux notify-send / mac)."""
        def worker():
            try:
                if os.name == "nt":
                    ps = (
                        "$ErrorActionPreference='SilentlyContinue';"
                        "[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]|Out-Null;"
                        "$t=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);"
                        "$x=$t.GetElementsByTagName('text');"
                        f"$x[0].AppendChild($t.CreateTextNode('{title}'))|Out-Null;"
                        f"$x[1].AppendChild($t.CreateTextNode('{msg}'))|Out-Null;"
                        "$n=[Windows.UI.Notifications.ToastNotification]::new($t);"
                        "[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Zyng VPN').Show($n);"
                    )
                    subprocess.Popen(["powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", ps],
                                     creationflags=subprocess.CREATE_NO_WINDOW,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                elif sys.platform == "darwin":
                    subprocess.Popen(["osascript", "-e",
                                      f'display notification "{msg}" with title "{title}"'],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                else:
                    subprocess.Popen(["notify-send", "-a", "Zyng VPN", title, msg],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
        threading.Thread(target=worker, daemon=True).start()

    def _flash(self, txt, color=None):
        # Не color=MUTED в сигнатуре: значения по умолчанию вычисляются при
        # импорте модуля, а тема применяется позже — цвет остался бы от
        # палитры, которая была на момент загрузки файла.
        self.status.configure(text=txt, text_color=color or MUTED)
        self.root.after(2500, lambda: self.status.configure(
            text=(tr("Подключено", "Connected") if self.connected
                  else tr("Отключено", "Disconnected")),
            text_color=(OK if self.connected else MUTED)))

    @staticmethod
    def _friendly_err(e):
        """Технические сетевые ошибки → понятный текст, без пугающих Errno."""
        s = str(e).lower()
        if any(k in s for k in ("getaddrinfo", "errno 11001", "errno -2", "name or service",
                                "temporary failure", "urlopen", "timed out", "timeout",
                                "connection", "network is unreachable", "ssl")):
            return "Нет интернета или сервер недоступен"
        return "Не удалось выполнить"

    @staticmethod
    def _lerp_hex(a, b, t):
        a = a.lstrip("#"); b = b.lstrip("#"); t = max(0.0, min(1.0, t))
        vals = [int(int(a[i:i+2], 16) + (int(b[i:i+2], 16) - int(a[i:i+2], 16)) * t) for i in (0, 2, 4)]
        return "#%02x%02x%02x" % tuple(vals)

    def _pill(self, cv, x0, y0, x1, y1, fill):
        """Рисует «пилюлю» (скруглённый прямоугольник) на Canvas."""
        d = y1 - y0
        cv.create_oval(x0, y0, x0 + d, y1, fill=fill, outline=fill)
        cv.create_oval(x1 - d, y0, x1, y1, fill=fill, outline=fill)
        cv.create_rectangle(x0 + d / 2, y0, x1 - d / 2, y1, fill=fill, outline=fill)

    def _draw_toggle(self):
        """Рисует тумблер по текущей позиции анимации self._tgl_pos (0..1)."""
        cv = getattr(self, "toggle_cv", None)
        if cv is None:
            return
        cv.delete("all")
        W, H = self.toggle_w, self.toggle_h
        m = 5
        p = getattr(self, "_tgl_pos", 0.0)
        track = self._lerp_hex(CARD2, ACC, p)            # плавный перелив дорожки
        self._pill(cv, m, m, W - m, H - m, track)
        d = (H - 2 * m) - 8                              # диаметр бегунка
        ky0 = m + 4
        off_x = m + 4
        on_x = W - m - 4 - d
        kx0 = off_x + (on_x - off_x) * p                 # плавное скольжение
        knob = self._lerp_hex("#8A94A6", "#ffffff", p)
        # лёгкая тень бегунка для объёма
        cv.create_oval(kx0 + 1, ky0 + 2, kx0 + d + 1, ky0 + d + 2, fill=track, outline=track)
        cv.create_oval(kx0, ky0, kx0 + d, ky0 + d, fill=knob, outline=knob)

    def _animate_toggle(self):
        """Плавно перегоняет бегунок в целевое состояние (ease-out)."""
        target = 1.0 if self.connected else 0.0
        try:
            if getattr(self, "_tgl_after", None):
                self.root.after_cancel(self._tgl_after); self._tgl_after = None
        except Exception:
            pass
        def step():
            diff = target - self._tgl_pos
            if abs(diff) < 0.02:
                self._tgl_pos = target; self._draw_toggle(); return
            self._tgl_pos += diff * 0.30                 # мягкое замедление
            self._draw_toggle()
            self._tgl_after = self.root.after(16, step)
        step()

    def _flag_image(self, code):
        if code in self._flag_cache:
            return self._flag_cache[code]
        img = None
        try:
            path = resource_path(os.path.join("flags", code.lower() + ".png"))
            if os.path.exists(path):
                from PIL import Image
                img = ctk.CTkImage(Image.open(path), size=(26, 18))
        except Exception:
            img = None
        self._flag_cache[code] = img
        return img

    def _flag_tk(self, code, size=20):
        """Круглый флаг (кроп в квадрат + маска-круг) как изображение для tk."""
        key = f"{code}:{size}"
        if not hasattr(self, "_flag_tk_cache"):
            self._flag_tk_cache = {}
        if key in self._flag_tk_cache:
            return self._flag_tk_cache[key]
        img = None
        try:
            path = resource_path(os.path.join("flags", code.lower() + ".png"))
            if os.path.exists(path):
                from PIL import Image, ImageDraw, ImageTk
                im = Image.open(path).convert("RGBA")
                # центр-кроп в квадрат
                w, h = im.size
                s = min(w, h)
                im = im.crop(((w - s) // 2, (h - s) // 2, (w - s) // 2 + s, (h - s) // 2 + s))
                ss = size * 4
                im = im.resize((ss, ss), Image.LANCZOS)
                mask = Image.new("L", (ss, ss), 0)
                ImageDraw.Draw(mask).ellipse((0, 0, ss, ss), fill=255)
                # тонкая светлая обводка
                ring = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
                ImageDraw.Draw(ring).ellipse((0, 0, ss - 1, ss - 1), outline=(255, 255, 255, 90),
                                             width=max(2, ss // 26))
                im.putalpha(mask)
                im = Image.alpha_composite(im, ring).resize((size, size), Image.LANCZOS)
                img = ImageTk.PhotoImage(im)
        except Exception:
            img = None
        self._flag_tk_cache[key] = img
        return img

    def _wheel(self, e):
        """Прокрутка колесом над лёгкими строками (быстро)."""
        cv = getattr(self.server_list, "_parent_canvas", None)
        if cv is None:
            return
        try:
            if getattr(e, "num", None) == 4:
                cv.yview_scroll(-3, "units")
            elif getattr(e, "num", None) == 5:
                cv.yview_scroll(3, "units")
            else:
                cv.yview_scroll(int(-e.delta / 40) or (-1 if e.delta > 0 else 1), "units")
        except Exception:
            pass

    def _on_tab_menu(self, label):
        key = self._tab_map.get(label)
        if key is not None:
            self.switch_tab(key)

    def render_tabs(self):
        tabs = [("all", "Все")]
        if self.manual_links:
            tabs.append(("manual", "Мои ключи"))
        for s in self.subs:
            tabs.append((s["url"], s.get("title") or tr("Подписка", "Subscription")))
        # уникальные подписи для выпадающего списка
        self._tab_map = {}
        values = []
        for key, label in tabs:
            lab = "".join(c for c in label if c.isprintable()).strip() or tr("Подписка", "Subscription")
            base = lab; i = 2
            while lab in self._tab_map:
                lab = f"{base} ({i})"; i += 1
            self._tab_map[lab] = key
            values.append(lab)
        self.tab_menu.configure(values=values)
        # текущее значение
        cur = next((l for l, k in self._tab_map.items() if k == self.active_tab), values[0])
        self.tab_menu.set(cur)

    # ── Список серверов ──
    def render_servers(self):
        self.render_tabs()
        for w in self.server_list.winfo_children():
            w.destroy()

        # Карточка подписки: имя, расход трафика, срок и кнопка удаления.
        cur_sub = next((s for s in self.subs if s["url"] == self.active_tab), None)
        show_sub = cur_sub or (self.sub_info and self.subs)
        if show_sub:
            si = self.sub_info or {}
            del_url = cur_sub["url"] if cur_sub else self.subs[-1]["url"]
            title = (cur_sub.get("title") if cur_sub else None) or si.get("title") \
                or tr("Подписка", "Subscription")
            card = ctk.CTkFrame(self.server_list, fg_color=CARD, corner_radius=16,
                                border_width=1, border_color=BORDER)
            card.pack(fill="x", pady=(0, 10))
            top = ctk.CTkFrame(card, fg_color="transparent")
            top.pack(fill="x", padx=14, pady=(12, 2))
            ctk.CTkLabel(top, text=title, font=ctk.CTkFont(FONT, 15, "bold"),
                         text_color=TEXT, anchor="w").pack(side="left")
            ctk.CTkButton(top, text="✕", width=30, height=28, corner_radius=14,
                          fg_color="transparent", hover_color=CARD2, text_color=DANGER,
                          font=ctk.CTkFont(FONT, 14, "bold"),
                          command=lambda u=del_url: self.delete_subscription(u)).pack(side="right")
            info_txt = (f"{si.get('traffic','∞')}   ·   {si.get('expire','')}" if si
                        else tr("нажми «Обновить», если пусто",
                                "press Refresh if this is empty"))
            ctk.CTkLabel(card, text=info_txt, font=ctk.CTkFont(FONT, 11),
                         text_color=MUTED, anchor="w").pack(anchor="w", padx=14, pady=(0, 12))

        if not self.links:
            self.empty_lbl = ctk.CTkLabel(
                self.server_list,
                text=tr("Серверов пока нет\n\nДобавь ключ или ссылку-подписку",
                        "No servers yet\n\nAdd a key or a subscription link"),
                font=ctk.CTkFont(FONT, 13), text_color=MUTED, justify="center")
            self.empty_lbl.pack(pady=60)
            return

        self._ping_lbls = {}
        self._rows = {}
        # Лёгкие tk-виджеты вместо CTk: строк бывает несколько сотен, и на
        # каждый CTk-виджет приходится свой canvas — прокрутка начинает дёргаться.
        for i, ln in enumerate(self.links):
            raw = unquote(ln.split("#", 1)[1]) if "#" in ln else f"Сервер {i+1}"
            name = clean_name(raw)
            code = country_of(raw)
            sel = (i == self.selected_idx)
            bg = CARD2 if sel else CARD

            row = tk.Frame(self.server_list, bg=bg, height=56)
            row.pack(fill="x", pady=4); row.pack_propagate(False)

            ph = self._flag_tk(code)
            badge = (tk.Label(row, image=ph, bg=bg) if ph
                     else tk.Label(row, text="🌐", bg=bg, font=(FONT, 18)))
            badge.pack(side="left", padx=(14, 12))

            m = tk.Frame(row, bg=bg); m.pack(side="left", fill="both", expand=True)
            disp = name if len(name) <= 24 else name[:23] + "…"
            l1 = tk.Label(m, text=disp, bg=bg, fg=TEXT, font=(FONT, 11, "bold"), anchor="w")
            l1.pack(anchor="w", pady=(10, 0))
            l2 = tk.Label(m, text=proto_line(ln), bg=bg, fg=MUTED, font=(FONT, 8), anchor="w")
            l2.pack(anchor="w")

            ptxt, pcol = self._ping_text(self.pings.get(i))
            pl = tk.Label(row, text=ptxt, bg=bg, fg=pcol, font=(FONT, 9, "bold"))
            pl.pack(side="right", padx=(0, 14))
            self._ping_lbls[i] = pl

            chev = tk.Label(row, text=("✓" if sel else "›"), bg=bg,
                            fg=(OK if sel else MUTED), font=(FONT, 13, "bold"))
            chev.pack(side="right", padx=(4, 10))

            self._rows[i] = {"bg": [row, m, badge, l1, l2, pl], "chev": chev}
            for w in (row, m, badge, l1, l2, pl, chev):
                w.bind("<Button-1>", lambda e, idx=i: self.select_server(idx))
                w.bind("<MouseWheel>", self._wheel)
                w.bind("<Button-4>", self._wheel)
                w.bind("<Button-5>", self._wheel)

    @staticmethod
    def _ping_text(ms):
        if ms is None: return "", MUTED
        if ms == "…": return "…", MUTED
        if ms == "x": return "—", MUTED
        col = OK if ms < 100 else (ACC if ms < 250 else DANGER)
        return tr(f"{ms} мс", f"{ms} ms"), col

    def _recolor_row(self, i, sel):
        r = getattr(self, "_rows", {}).get(i)
        if not r:
            return
        bg = CARD2 if sel else CARD
        try:
            for w in r["bg"]:
                w.configure(bg=bg)
            r["chev"].configure(bg=bg, text=("✓" if sel else "›"), fg=(OK if sel else MUTED))
        except Exception:
            pass

    def select_server(self, idx):
        prev = self.selected_idx
        self.selected_idx = idx
        # плавно: перекрашиваем только старую и новую строку, без полной перерисовки списка
        if getattr(self, "_rows", None) and idx in self._rows:
            self._recolor_row(prev, False)
            self._recolor_row(idx, True)
        else:
            self.render_servers()
        nm = clean_name(unquote(self.links[idx].split("#", 1)[1])) if "#" in self.links[idx] else f"Сервер {idx+1}"
        self._update_current(nm)
        self.do_ping()
        if self.connected: self.disconnect(); self.connect()

    def delete_server(self, idx):
        # Мгновенное удаление без модальных окон — надёжно и без ошибок
        try:
            if not (0 <= idx < len(self.links)):
                return
            was_current = (idx == self.selected_idx)
            link = self.links[idx]
            # удаляем это значение из источника (ручные ключи и все подписки)
            self.manual_links = [l for l in self.manual_links if l != link]
            for url, c in self.sub_cache.items():
                c["links"] = [l for l in c.get("links", []) if l != link]
            self.pings = {}
            if was_current and self.connected:
                self.disconnect()
            self._rebuild_links()
            self.render_servers()
            self.save(silent=True); self.do_ping()
            self._flash(tr("Сервер удалён", "Server removed"), MUTED)
        except Exception as e:
            self._flash(tr(f"Не удалось удалить: {e}", f"Could not remove: {e}"), DANGER)

    def delete_subscription(self, url):
        try:
            if self.connected: self.disconnect()
            self.subs = [s for s in self.subs if s["url"] != url]
            self.sub_cache.pop(url, None)
            if self.active_tab == url:
                self.active_tab = "all"
            self.pings = {}; self.selected_idx = 0
            self._rebuild_links(); self.render_servers()
            self.save(silent=True); self.do_ping()
            self._flash(tr("Подписка удалена", "Subscription removed"), MUTED)
        except Exception as e:
            self._flash(f"Ошибка: {e}", DANGER)

    def clear_servers(self):
        try:
            if not self.links:
                self._flash(tr("Список уже пуст", "The list is already empty"), MUTED); return
            if self.connected: self.disconnect()
            # чистим ТОЛЬКО активную вкладку, чтобы можно было удалять по подпискам
            tab = self.active_tab
            if tab == "manual":
                self.manual_links = []
            elif tab != "all" and tab in self.sub_cache:
                self.subs = [s for s in self.subs if s["url"] != tab]
                self.sub_cache.pop(tab, None)
                self.active_tab = "all"
            else:
                self.manual_links = []; self.subs = []; self.sub_cache = {}
            self.pings = {}; self.selected_idx = 0
            self._rebuild_links(); self.render_servers()
            self.save(silent=True)
            self._flash(tr("Очищено", "Cleared"), MUTED)
        except Exception as e:
            self._flash(f"Ошибка: {e}", DANGER)

    def _current_link(self):
        if self.links and 0 <= self.selected_idx < len(self.links):
            return self.links[self.selected_idx]
        return ""

    def connect_fastest(self):
        """Пингует все серверы и подключается к самому быстрому."""
        if not self.links:
            self._flash(tr("Нет серверов", "No servers"), DANGER); return
        self._flash(tr("Ищу быстрый сервер…", "Looking for the fastest server…"), MUTED)
        def worker():
            best = None; bestms = None
            for i, ln in enumerate(self.links):
                h, p = link_host_port(ln)
                if not h:
                    continue
                ms = tcp_ping(h, p, timeout=2.5)
                if ms is not None and (bestms is None or ms < bestms):
                    bestms = ms; best = i
            def done():
                if best is None:
                    self._flash(tr("Серверы не отвечают", "No server responded"), WARN); return
                self.selected_idx = best
                nm = clean_name(unquote(self.links[best].split("#", 1)[1])) if "#" in self.links[best] else "Сервер"
                self._update_current(nm); self.render_servers()
                if self.connected:
                    self.disconnect(); self.connect()
                else:
                    self.connect()
                self._flash(tr(f"⚡ Быстрый: {nm} ({bestms} мс)", f"⚡ Fastest: {nm} ({bestms} ms)"), OK)
            self.root.after(0, done)
        threading.Thread(target=worker, daemon=True).start()

    def copy_key(self):
        """Копирует ссылку выбранного сервера в буфер обмена."""
        link = self._current_link()
        if not link:
            self._flash(tr("Сервер не выбран", "No server selected"), WARN); return
        try:
            self.root.clipboard_clear(); self.root.clipboard_append(link)
            self._flash(tr("Ключ скопирован ✓", "Key copied ✓"), OK)
        except Exception:
            self._flash(tr("Не удалось скопировать", "Could not copy"), DANGER)

    # ── Пинг ── (меряем все серверы разом и показываем в каждой строке)
    def do_ping(self):
        link = self._current_link()
        if link:
            host, port = link_host_port(link)
            if host:
                self.ping_lbl.configure(text=tr("Проверка…", "Checking…"), text_color=MUTED)
                def w0(h=host, p=port):
                    ms = tcp_ping(h, p)
                    def show():
                        if ms is None: self.ping_lbl.configure(text=tr("Пинг: нет ответа", "Ping: no response"), text_color=MUTED)
                        else:
                            col = OK if ms < 150 else (WARN if ms < 400 else DANGER)
                            self.ping_lbl.configure(text=tr(f"Пинг: {ms} мс", f"Ping: {ms} ms"), text_color=col)
                    self.root.after(0, show)
                threading.Thread(target=w0, daemon=True).start()
        # очередь всех серверов + ограниченный пул воркеров (не спамим сокетами)
        import queue
        gen = getattr(self, "_ping_gen", 0) + 1
        self._ping_gen = gen
        q = queue.Queue()
        for i, ln in enumerate(self.links):
            host, port = link_host_port(ln)
            if host:
                self.pings[i] = "…"          # показываем «идёт проверка»
                q.put((i, host, port))
            else:
                self.pings[i] = "x"
        # сразу перерисуем метки в состояние «…», чтобы было видно, что крутится
        for i in range(len(self.links)):
            self._update_ping_lbl(i)
        def worker():
            while gen == self._ping_gen:
                try:
                    idx, h, p = q.get_nowait()
                except Exception:
                    return
                ms = tcp_ping(h, p, timeout=4.0)
                if gen != self._ping_gen:
                    return
                self.pings[idx] = ms if ms is not None else "x"
                self.root.after(0, lambda i=idx: self._update_ping_lbl(i))
        for _ in range(min(10, max(1, q.qsize()))):
            threading.Thread(target=worker, daemon=True).start()

    def _update_ping_lbl(self, idx):
        lbl = self._ping_lbls.get(idx)
        if lbl is not None and lbl.winfo_exists():
            txt, col = self._ping_text(self.pings.get(idx))
            lbl.configure(text=txt, fg=col)   # tk.Label использует fg

    # ── Подключение ──
    def toggle(self):
        self.disconnect() if self.connected else self.connect()

    def connect(self):
        link = self._current_link()
        if not link:
            self._flash(tr("Добавь и выбери сервер", "Add a server and select it"), DANGER); return
        use_sb = link.strip().startswith("sb://")
        flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        env = dict(os.environ)
        cfgdir = os.path.dirname(CONFIG_FILE)
        try:
            if use_sb:                                    # hysteria2 / tuic → ядро sing-box
                outbound = _parse_sblink(link)
                engine = resource_path("sing-box.exe" if os.name == "nt" else "sing-box")
                if not os.path.exists(engine):
                    self._flash(tr("Не найден sing-box", "sing-box not found"), DANGER); return
                cfg = os.path.join(cfgdir, ".zyng_singbox.json")
                with open(cfg, "w", encoding="utf-8") as f:
                    json.dump(build_singbox_config(outbound, self.prefs), f)
                cmd = [engine, "run", "-c", cfg]
            else:
                outbound = parse_link(link)
                engine = resource_path("xray.exe" if os.name == "nt" else "xray")
                if not os.path.exists(engine):
                    self._flash(tr("Не найден xray", "xray not found"), DANGER); return
                # geoip.dat/geosite.dat лежат рядом с ядром — укажем ядру, где их искать
                env["XRAY_LOCATION_ASSET"] = os.path.dirname(engine)
                cfg = os.path.join(cfgdir, ".zyng_xray.json")
                with open(cfg, "w", encoding="utf-8") as f:
                    json.dump(build_xray_config(outbound, self.prefs), f)
                cmd = [engine, "run", "-config", cfg]
        except Exception as e:
            self._flash(tr(f"Неверный ключ: {e}", f"Invalid key: {e}"), DANGER); return
        # Вывод ядра — в файл, а не в никуда.
        #
        # Раньше стоял DEVNULL, и когда ядро отказывалось стартовать, причина
        # пропадала бесследно. Теперь при неудаче мы можем показать её словами.
        errlog = os.path.join(cfgdir, ".zyng_core.log")
        try:
            ef = open(errlog, "w", encoding="utf-8", errors="replace")
        except Exception:
            ef = subprocess.DEVNULL

        try:
            self.proc = subprocess.Popen(cmd, env=env,
                stdout=ef, stderr=subprocess.STDOUT, creationflags=flags)
        except Exception as e:
            self._flash(tr(f"Ядро: {e}", f"Core: {e}"), DANGER); return

        # ПРОВЕРЯЕМ, что ядро действительно поднялось.
        #
        # Здесь была главная беда: сразу после запуска процесса приложение
        # писало «Подключено» и включало системный прокси. Если ядро падало на
        # старте — неверный ключ, занятый порт, отсутствующий geoip, — человек
        # видел «Подключено», а страницы не открывались вообще ничего, и понять
        # причину было неоткуда.
        deadline = time.time() + 3.0
        while time.time() < deadline:
            if self.proc.poll() is not None:
                break
            if _port_open("127.0.0.1", HTTP_PORT) or _port_open("127.0.0.1", SOCKS_PORT):
                break
            time.sleep(0.1)

        if self.proc.poll() is not None:
            try:
                ef.close()
            except Exception:
                pass
            self.proc = None
            self._flash(tr(f"Ядро не запустилось: {_last_core_error(errlog)}",
                           f"The core did not start: {_last_core_error(errlog)}"), DANGER)
            return

        if not (_port_open("127.0.0.1", HTTP_PORT) or _port_open("127.0.0.1", SOCKS_PORT)):
            # Процесс жив, но порт не слушает — трафику идти некуда.
            try:
                self.proc.kill()
            except Exception:
                pass
            self.proc = None
            self._flash(tr(f"Ядро не открыло порт: {_last_core_error(errlog)}",
                           f"The core opened no port: {_last_core_error(errlog)}"), DANGER)
            return
        # TUN-режим: весь трафик системы через sing-box tun → наш локальный socks
        self.tun_proc = None
        if self.prefs.get("tun_mode"):
            sb = resource_path("sing-box.exe" if os.name == "nt" else "sing-box")
            if os.path.exists(sb):
                try:
                    tcfg = os.path.join(cfgdir, ".zyng_tun.json")
                    with open(tcfg, "w", encoding="utf-8") as f:
                        json.dump(build_tun_config(self.prefs), f)
                    self.tun_proc = subprocess.Popen([sb, "run", "-c", tcfg], env=env,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=flags)
                    time.sleep(0.6)
                    if self.tun_proc.poll() is not None:   # упал — скорее всего нет прав админа
                        self.tun_proc = None
                        self._flash(tr("TUN не запущен — запусти от администратора", "TUN did not start — run as administrator"), WARN)
                except Exception:
                    self.tun_proc = None
        if not self.tun_proc:                              # прокси-режим (или TUN не поднялся)
            try: set_system_proxy(True)
            except Exception: pass
        self.connected = True
        nm = clean_name(unquote(link.split("#", 1)[1])) if "#" in link else "Сервер"
        self._update_current(nm)
        self._animate_toggle()
        self._connect_time = time.time()
        self._tick()
        self._verify_traffic()

    def _verify_traffic(self):
        """Проверяет, что через поднятый прокси реально ходит трафик.

        Ядро может запуститься, открыть порт и при этом не пропускать ничего:
        неверный пароль, сервер не отвечает, транспорт не совпал. Порт слушает,
        приложение говорит «Подключено», а страницы не открываются — и человеку
        неоткуда узнать, что не так. Поэтому спрашиваем у самого прокси.
        """
        gen = getattr(self, "_verify_gen", 0) + 1
        self._verify_gen = gen

        def worker():
            time.sleep(1.0)                      # даём ядру договориться с сервером
            if gen != self._verify_gen or not self.connected:
                return
            ok, why = _proxy_works(SOCKS_PORT)
            if gen != self._verify_gen or not self.connected:
                return
            if ok:
                self.root.after(0, lambda: self._flash(
                    tr("Подключено", "Connected"), OK))
            else:
                self.root.after(0, lambda w=why: self._flash(
                    tr(f"Туннель поднят, но трафик не идёт: {w}",
                       f"The tunnel is up but no traffic passes: {w}"), DANGER))

        threading.Thread(target=worker, daemon=True).start()

    def _restore_current_label(self):
        """Подставляет в правую колонку сервер, выбранный в прошлый раз."""
        try:
            link = self._current_link()
            if not link:
                return
            nm = (clean_name(unquote(link.split("#", 1)[1]))
                  if "#" in link else tr("Сервер", "Server"))
            self._update_current(nm)
        except Exception:
            # Не показать имя — досадно, но не повод не запуститься.
            pass

    def _update_current(self, nm):
        self.cur_lbl.configure(text=nm)
        try:
            link = self._current_link()
            self.cur_sub_lbl.configure(text=proto_line(link) if link else "")
        except Exception:
            pass
        try:
            ph = self._flag_tk(country_of(nm), size=28)
            if ph:
                self.cur_flag.configure(image=ph); self._cur_flag_ref = ph
            else:
                self.cur_flag.configure(image="")
        except Exception:
            pass

    def _tick(self):
        """Таймер подключения + сторож автопереподключения."""
        if not self.connected or not self._connect_time:
            return
        # ядро упало? — авто-переподключение (если включено)
        if self.proc and self.proc.poll() is not None and self.prefs.get("auto_reconnect", True):
            self._auto_reconnect(); return
        s = int(time.time() - self._connect_time)
        hhmmss = f"{s//3600:02d}:{(s%3600)//60:02d}:{s%60:02d}"
        self.timer_lbl.configure(text=hhmmss, text_color=TEXT)
        self.status.configure(text=tr("Подключено", "Connected"), text_color=OK)
        self._tick_after = self.root.after(1000, self._tick)

    def _auto_reconnect(self):
        if getattr(self, "_reconnecting", False):
            return
        self._reconnecting = True
        self._flash(tr("Соединение потеряно — переподключаюсь…", "Connection lost — reconnecting…"), WARN)
        self.status.configure(text=tr("Переподключение…", "Reconnecting…"), text_color=WARN)
        self.disconnect()
        def again():
            self.connect()
            self._reconnecting = False
        self.root.after(1000, again)

    def disconnect(self):
        try: set_system_proxy(False)
        except Exception: pass
        if getattr(self, "tun_proc", None):
            try: self.tun_proc.terminate()
            except Exception: pass
            self.tun_proc = None
        if self.proc:
            try: self.proc.terminate()
            except Exception: pass
            self.proc = None
        self.connected = False
        self._connect_time = None
        try:
            if getattr(self, "_tick_after", None):
                self.root.after_cancel(self._tick_after); self._tick_after = None
        except Exception:
            pass
        self._animate_toggle()
        self.timer_lbl.configure(text="00:00:00", text_color=MUTED)
        self.status.configure(text=tr("Отключено", "Disconnected"), text_color=MUTED)

    # ── Сохранение ──
    def save(self, silent=False):
        try:
            with open(CONFIG_FILE, "w", encoding="utf-8") as f:
                json.dump({"manual_links": self.manual_links,
                           "subs": self.subs, "sub_cache": self.sub_cache,
                           "active_tab": self.active_tab,
                           "autoconnect": self.autoconnect, "prefs": self.prefs}, f)
            if not silent: self._flash(tr("Сохранено ✓", "Saved ✓"), OK)
        except Exception:
            pass

    def load_saved(self):
        try:
            with open(CONFIG_FILE, encoding="utf-8") as f:
                d = json.load(f)
                self.manual_links = d.get("manual_links", []) or []
                self.subs = d.get("subs", []) or []
                self.sub_cache = d.get("sub_cache", {}) or {}
                self.active_tab = d.get("active_tab", "all") or "all"
                self.autoconnect = bool(d.get("autoconnect", False))
                self.prefs = d.get("prefs", {}) or {}
                # миграция со старого формата (одна подписка + links)
                old_links = d.get("links", []) or []
                old_sub = d.get("sub_url", "")
                if old_sub and not self.subs:
                    self.subs = [{"url": old_sub, "title": _sub_title(old_sub)}]
                    self.sub_cache[old_sub] = {"links": old_links, "info": {}}
                elif old_links and not self.manual_links and not self.subs:
                    self.manual_links = old_links
        except Exception:
            pass
        self._rebuild_links()

    def _rebuild_links(self):
        """Собирает self.links по активной вкладке из ручных ключей и подписок."""
        tab = self.active_tab
        if tab == "manual":
            links = list(self.manual_links)
            self.sub_info = {}
        elif tab != "all" and any(s["url"] == tab for s in self.subs):
            links = list(self.sub_cache.get(tab, {}).get("links", []))
            self.sub_info = self.sub_cache.get(tab, {}).get("info", {})
        else:  # all
            links = list(self.manual_links)
            for s in self.subs:
                links += self.sub_cache.get(s["url"], {}).get("links", [])
            self.sub_info = self.sub_cache.get(self.subs[-1]["url"], {}).get("info", {}) if self.subs else {}
        # raw hysteria2/hysteria/tuic ключи → sb:// (ядро sing-box)
        norm = []
        for k in links:
            try:
                if k.startswith(("hysteria2://", "hy2://")): k = _hy2_url_to_sb(k)
                elif k.startswith("hysteria://"):            k = _hysteria_url_to_sb(k)
                elif k.startswith("tuic://"):                k = _tuic_url_to_sb(k)
            except Exception:
                continue
            norm.append(k)
        # жёсткий предел — иначе «толстая» подписка (тысячи серверов) вешает интерфейс
        self.links = norm[:MAX_SERVERS]
        if self.selected_idx >= len(self.links):
            self.selected_idx = max(0, len(self.links) - 1)

    def switch_tab(self, tab):
        self.active_tab = tab
        self.selected_idx = 0
        self._rebuild_links(); self.render_servers(); self.do_ping(); self.save(silent=True)

    def update_sub(self):
        if not self.subs:
            self._flash(tr("Нет подписок", "No subscriptions"), DANGER); return
        self._pull_all_subs(reconnect=True)

    def _pull_all_subs(self, reconnect=False):
        if getattr(self, "_subs_updating", False):
            return
        self._subs_updating = True
        self._flash(tr("Обновление подписок…", "Refreshing subscriptions…"), MUTED)
        subs = list(self.subs)
        # ВСЁ в фоне — интерфейс не зависает, ключи можно вставлять параллельно
        def worker():
            results = {}
            for s in subs:
                try:
                    links, info = fetch_subscription(s["url"])
                    if links:
                        results[s["url"]] = (links, info)
                except Exception:
                    pass
            def done():
                self._subs_updating = False
                for url, (links, info) in results.items():
                    self.sub_cache[url] = {"links": links[:MAX_SERVERS], "info": info}
                    for s in self.subs:
                        if s["url"] == url and info.get("title"):
                            s["title"] = info["title"]
                self._rebuild_links(); self.render_servers(); self.save(silent=True); self.do_ping()
                if results:
                    self._flash(tr(f"Обновлено подписок: {len(results)}", f"Subscriptions refreshed: {len(results)}"), OK)
                else:
                    self._flash(tr("Нет интернета или подписки недоступны", "No internet, or subscriptions unreachable"), WARN)
                if reconnect and self.connected: self.disconnect(); self.connect()
            self.root.after(0, done)
        threading.Thread(target=worker, daemon=True).start()

    # ── Обновление приложения ──
    def check_update(self, periodic=True):
        def worker():
            try:
                import ssl
                ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
                # cache-buster: raw.githubusercontent кэшируется ~5 мин на CDN,
                # из-за этого «у одних сразу, у других долго». Обходим кэш.
                cb = "?t=%d" % int(time.time())
                hdr = {"User-Agent": "Zyng", "Cache-Control": "no-cache", "Pragma": "no-cache"}
                latest = ""; notes = ""
                # 1) манифест RELEASE.json (версия + «что нового»); 2) фолбэк на version.txt
                try:
                    req = urllib.request.Request(RELEASE_JSON_URL + cb, headers=hdr)
                    data = json.loads(urllib.request.urlopen(req, timeout=10, context=ctx).read().decode())
                    latest = str(data.get("version", "")).strip()
                    notes = _changelog_text(data) or str(data.get("notes", "")).strip()
                except Exception:
                    req = urllib.request.Request(VERSION_URL + cb, headers=hdr)
                    latest = urllib.request.urlopen(req, timeout=10, context=ctx).read().decode().strip()
                # обновляемся, когда версия ОТЛИЧАЕТСЯ (в т.ч. после сброса на 2.0)
                if latest and latest != APP_VERSION:
                    self.root.after(0, lambda l=latest, n=notes: self._show_update(l, n))
            except Exception:
                pass
        threading.Thread(target=worker, daemon=True).start()
        # периодически перепроверяем (каждые 3 мин), пока приложение открыто —
        # чтобы уведомление об обновлении дошло до всех, а не только при запуске
        if periodic:
            self.root.after(180000, lambda: self.check_update(periodic=True))

    @staticmethod
    def _newer(a, b):
        try: return [int(x) for x in a.split(".")] > [int(x) for x in b.split(".")]
        except Exception: return a != b

    def _show_update(self, latest, notes=""):
        self._latest = latest
        if self.update_bar: return
        # Внизу окна, а не сверху.
        #
        # Сверху плашка ложилась поверх шапки и списка серверов и закрывала
        # работу. Внизу она на виду, но ничему не мешает, и её видно целиком
        # вместе с описанием того, что изменилось.
        self.update_bar = ctk.CTkFrame(self.root, fg_color=UPDCARD, corner_radius=16,
                                       border_width=1, border_color=OK)
        self.update_bar.place(relx=0.5, rely=0.985, anchor="s")

        # Одна строка, ничего лишнего.
        #
        # Раньше плашка разворачивала под собой весь список изменений и
        # занимала половину окна. Уведомление должно сообщать факт и давать
        # действие, а подробности человек прочитает на странице релиза.
        top = ctk.CTkFrame(self.update_bar, fg_color="transparent"); top.pack(fill="x")
        self._ulbl = ctk.CTkLabel(
            top, text=tr(f"Версия {latest}", f"Version {latest}"),
            font=ctk.CTkFont(FONT, 12, "bold"), text_color=OK)
        self._ulbl.pack(side="left", padx=(14, 8), pady=7)

        # Крестик: обновление — предложение, а не требование. Без него плашка
        # висела до перезапуска, и закрыть её было нечем.
        ctk.CTkButton(top, text="✕", width=24, height=24, corner_radius=12,
                      fg_color="transparent", hover_color=CARD2, text_color=MUTED,
                      font=ctk.CTkFont(FONT, 12, "bold"),
                      command=self._hide_update).pack(side="right", padx=(2, 8), pady=7)
        ctk.CTkButton(top, text=tr("Обновить", "Update"), width=88, height=26, corner_radius=13,
                      fg_color=OK, hover_color="#2FB37A", text_color="#08160c",
                      font=ctk.CTkFont(FONT, 11, "bold"),
                      command=self.do_self_update).pack(side="right", padx=2, pady=7)

    def _hide_update(self):
        """Убирает плашку. Следующая проверка покажет её снова — это не отказ
        от обновления, а «сейчас не до того»."""
        try:
            if self.update_bar:
                self.update_bar.destroy()
        except Exception:
            pass
        self.update_bar = None

    def do_self_update(self):
        # macOS-сборки больше нет — на Mac (и в dev-режиме) открываем страницу релиза
        if not getattr(sys, "frozen", False) or sys.platform == "darwin":
            import webbrowser; webbrowser.open(RELEASES_URL); return
        asset = "Zyng.exe" if os.name == "nt" else "Zyng-linux"
        url = f"{DOWNLOAD_BASE}/{asset}"; cur = sys.executable; new = cur + ".new"
        def setl(t):
            if hasattr(self, "_ulbl"):
                self.root.after(0, lambda: self._ulbl.configure(text=t))
        setl("⏳ Скачиваю… 0%")
        def worker():
            try:
                import ssl
                ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
                req = urllib.request.Request(url, headers={"User-Agent": "Zyng"})
                try:
                    if os.path.exists(new): os.remove(new)
                except Exception: pass
                with urllib.request.urlopen(req, timeout=60, context=ctx) as r:
                    total = int(r.headers.get("Content-Length", 0)); done = 0
                    with open(new, "wb") as f:
                        while True:
                            chunk = r.read(65536)
                            if not chunk: break
                            f.write(chunk); done += len(chunk)
                            if total: setl(f"⏳ Скачиваю… {done*100//total}%")
                size = os.path.getsize(new)
                # СТРОГАЯ проверка целостности — иначе будет битый exe
                if size < 1_000_000:
                    raise Exception("файл слишком мал")
                if total and size != total:
                    raise Exception("скачан не полностью")
                with open(new, "rb") as f:
                    head = f.read(4)
                if os.name == "nt" and head[:2] != b"MZ":
                    raise Exception("не Windows-программа")
                elif os.name != "nt" and sys.platform != "darwin" and head[:2] != b"\x7fE":
                    raise Exception("не Linux-программа")
                elif sys.platform == "darwin":
                    # macOS: Mach-O (0xFEEDFACE/CF, 0xCAFEBABE) — проверяем магию
                    if head not in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                                    b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"):
                        raise Exception("не macOS-программа")
                setl("✅ Применяю…")
                self.root.after(0, lambda: self._apply_update(cur, new))
            except Exception as e:
                try:
                    if os.path.exists(new): os.remove(new)
                except Exception: pass
                setl(f"Ошибка — жми ещё раз")
        threading.Thread(target=worker, daemon=True).start()

    def _apply_update(self, cur, new):
        if self.connected: self.disconnect()
        try:
            if os.name == "nt":
                old = cur + ".old"
                bat = cur + "_upd.bat"
                # Работающий exe нельзя удалить, но МОЖНО переименовать → так безопасно
                cdir = os.path.dirname(cur)
                with open(bat, "w") as f:
                    f.write("@echo off\r\nping 127.0.0.1 -n 5 >nul\r\n"
                            ":retry\r\n"
                            f'if exist "{cur}" (move /y "{cur}" "{old}" >nul 2>&1)\r\n'
                            f'move /y "{new}" "{cur}" >nul 2>&1\r\n'
                            f'if not exist "{cur}" (ping 127.0.0.1 -n 2 >nul & goto retry)\r\n'
                            # ВАЖНО: очищаем переменные PyInstaller, унаследованные от старого
                            # процесса. Иначе новый exe пытается грузить python3xx.dll из уже
                            # удалённой временной папки → «Failed to load Python DLL».
                            'set "_MEIPASS2="\r\n'
                            'set "_PYI_ARCHIVE_FILE="\r\n'
                            'set "_PYI_APPLICATION_HOME_DIR="\r\n'
                            'set "_PYI_PARENT_PROCESS_LEVEL="\r\n'
                            'set "_PYI_ONEDIR_MODE="\r\n'
                            f'start "" /d "{cdir}" "{cur}"\r\n'
                            f'ping 127.0.0.1 -n 2 >nul\r\n'
                            f'del /f /q "{old}" >nul 2>&1\r\n'
                            f'del /f /q "{new}" >nul 2>&1\r\n'
                            f'del "%~f0"\r\n')
                # запускаем bat в ЧИСТОМ окружении, без переменных PyInstaller
                clean_env = {k: v for k, v in os.environ.items()
                             if not (k.startswith("_MEIPASS") or k.startswith("_PYI"))}
                subprocess.Popen(["cmd", "/c", bat], creationflags=subprocess.CREATE_NO_WINDOW,
                                 env=clean_env)
            else:
                os.chmod(new, 0o755); sh = cur + "_upd.sh"
                with open(sh, "w") as f:
                    f.write(f'#!/bin/sh\nsleep 2\nmv -f "{new}" "{cur}"\nchmod +x "{cur}"\n'
                            f'xattr -dr com.apple.quarantine "{cur}" 2>/dev/null || true\n'
                            f'unset _MEIPASS2 _PYI_ARCHIVE_FILE _PYI_APPLICATION_HOME_DIR _PYI_PARENT_PROCESS_LEVEL\n'
                            f'nohup "{cur}" >/dev/null 2>&1 &\nrm -- "$0"\n')
                clean_env = {k: v for k, v in os.environ.items()
                             if not (k.startswith("_MEIPASS") or k.startswith("_PYI"))}
                os.chmod(sh, 0o755); subprocess.Popen(["/bin/sh", sh], env=clean_env)
            self.root.after(300, self.on_close)
        except Exception:
            pass

    # ── Настройки ──
    def open_settings(self):
        win = ctk.CTkToplevel(self.root); win.title(tr("Настройки", "Settings")); win.geometry("420x640")
        win.configure(fg_color=BG)
        win.after(250, lambda: (win.lift(), win.focus_force()))
        ctk.CTkLabel(win, text=tr("Настройки", "Settings"), font=ctk.CTkFont(FONT, 20, "bold"), text_color=TEXT).pack(pady=(16, 8))
        sc = ctk.CTkScrollableFrame(win, fg_color="transparent"); sc.pack(fill="both", expand=True, padx=10)
        def section(t):
            ctk.CTkLabel(sc, text=t, font=ctk.CTkFont(FONT, 10, "bold"), text_color=MUTED).pack(anchor="w", padx=10, pady=(14, 4))
            c = ctk.CTkFrame(sc, fg_color=CARD, corner_radius=16, border_width=1, border_color=BORDER); c.pack(fill="x"); return c
        def sw(card, text, key, default=False, cmd=None):
            row = ctk.CTkFrame(card, fg_color="transparent"); row.pack(fill="x", padx=14, pady=8)
            ctk.CTkLabel(row, text=text, font=ctk.CTkFont(FONT, 13), text_color=TEXT).pack(side="left")
            v = ctk.StringVar(value="on" if self.prefs.get(key, default) else "off")
            def on():
                self.prefs[key] = (v.get() == "on"); self.save(silent=True)
                if cmd: cmd(v.get() == "on")
            ctk.CTkSwitch(row, text="", variable=v, onvalue="on", offvalue="off", command=on, progress_color=ACC).pack(side="right")
        def choice(card, text, key, opts, default, on_change=None):
            row = ctk.CTkFrame(card, fg_color="transparent"); row.pack(fill="x", padx=14, pady=8)
            ctk.CTkLabel(row, text=text, font=ctk.CTkFont(FONT, 13), text_color=TEXT).pack(side="left")
            var = ctk.StringVar(value=self.prefs.get(key, default))
            def _cb(v):
                self.prefs[key] = v; self.save(silent=True)
                if on_change: on_change(v)
            ctk.CTkOptionMenu(row, values=opts, variable=var, width=130, fg_color=CARD2,
                              text_color=TEXT, button_color=ACC, button_hover_color=ACC_D,
                              command=_cb).pack(side="right")
        def link(card, text, cmd, color=None):
            color = color or TEXT
            ctk.CTkButton(card, text=text, anchor="w", height=38, corner_radius=0, fg_color="transparent",
                          hover_color=CARD2, text_color=color, font=ctk.CTkFont(FONT, 13), command=cmd).pack(fill="x", padx=4, pady=1)

        c = section(tr("ОФОРМЛЕНИЕ", "APPEARANCE"))

        # Значение в настройках хранится кодом ("dark"), а показывается словом.
        # Раньше хранилось само слово — при смене языка выбор бы потерялся.
        theme_names = {
            "system": tr("Как в системе", "System"),
            "light":  tr("Светлая", "Light"),
            "dark":   tr("Тёмная", "Dark"),
            "black":  tr("Чёрная", "Black"),
        }
        lang_names = {"system": tr("Как в системе", "System"), "ru": "Русский", "en": "English"}

        def coded_choice(card, text, key, names, default, hint=None):
            row = ctk.CTkFrame(card, fg_color="transparent"); row.pack(fill="x", padx=14, pady=8)
            left = ctk.CTkFrame(row, fg_color="transparent"); left.pack(side="left", anchor="w")
            ctk.CTkLabel(left, text=text, font=ctk.CTkFont(FONT, 13), text_color=TEXT).pack(anchor="w")
            if hint:
                ctk.CTkLabel(left, text=hint, font=ctk.CTkFont(FONT, 10),
                             text_color=MUTED).pack(anchor="w")
            current = self.prefs.get(key, default)
            var = ctk.StringVar(value=names.get(current, names[default]))
            back = {v: k for k, v in names.items()}
            def _cb(shown):
                self.prefs[key] = back.get(shown, default); self.save(silent=True)
                self._need_restart(win)
            ctk.CTkOptionMenu(row, values=list(names.values()), variable=var, width=140,
                              fg_color=CARD2, text_color=TEXT, button_color=ACC,
                              button_hover_color=ACC_D, command=_cb).pack(side="right")

        coded_choice(c, tr("Тема", "Theme"), "theme", theme_names, "dark",
                     hint=tr("Чёрная экономит батарею на OLED",
                             "Black saves battery on OLED"))
        coded_choice(c, tr("Язык", "Language"), "lang", lang_names, "system")
        c = section(tr("ЗАПУСК", "STARTUP"))
        srow = ctk.CTkFrame(c, fg_color="transparent"); srow.pack(fill="x", padx=14, pady=8)
        ctk.CTkLabel(srow, text=tr("Автозапуск при входе", "Launch at login"), font=ctk.CTkFont(FONT, 13), text_color=TEXT).pack(side="left")
        asv = ctk.StringVar(value="on" if get_autostart() else "off")
        ctk.CTkSwitch(srow, text="", variable=asv, onvalue="on", offvalue="off",
                      command=lambda: set_autostart(asv.get() == "on"), progress_color=ACC).pack(side="right")
        arow = ctk.CTkFrame(c, fg_color="transparent"); arow.pack(fill="x", padx=14, pady=8)
        ctk.CTkLabel(arow, text=tr("Автоподключение", "Connect on launch"), font=ctk.CTkFont(FONT, 13)).pack(side="left")
        acv = ctk.StringVar(value="on" if self.autoconnect else "off")
        ctk.CTkSwitch(arow, text="", variable=acv, onvalue="on", offvalue="off",
                      command=lambda: (setattr(self, "autoconnect", acv.get() == "on"), self.save(silent=True)),
                      progress_color=ACC).pack(side="right")
        sw(c, tr("Автопереподключение при обрыве", "Reconnect automatically"), "auto_reconnect", True)
        c = section(tr("ТУННЕЛЬ", "TUNNEL"))
        sw(c, tr("Фрагментация TLS (обход DPI)", "TLS fragmentation (DPI bypass)"), "fragment", False,
           cmd=lambda _v: self._reconnect_note())
        sw(c, tr("Доступ из локальной сети (LAN)", "Allow LAN access"), "lan", False,
           cmd=lambda _v: self._reconnect_note())
        c = section(tr("МАРШРУТИЗАЦИЯ", "ROUTING"))
        sw(c, tr("Умная (RU-сайты напрямую)", "Smart (local sites go direct)"), "route_smart", False,
           cmd=lambda _v: self._reconnect_note())
        sw(c, tr("Steam-загрузки напрямую (быстрые игры)", "Steam downloads go direct"), "steam_direct", False,
           cmd=lambda _v: self._reconnect_note())
        sw(c, tr("Режим TUN — весь ПК (нужен админ)", "TUN mode — whole PC (needs admin)"), "tun_mode", False,
           cmd=lambda _v: self._reconnect_note())
        c = section(tr("ДАННЫЕ", "DATA"))
        link(c, tr("📋 Скопировать текущий ключ", "📋 Copy current key"), self.copy_key, color=ACC)
        link(c, tr("🗑 Сброс (удалить ключи)", "🗑 Reset (delete all keys)"), self._reset_key, color=DANGER)
        c = section(tr("ПОДРОБНЕЕ", "MORE"))
        link(c, tr(f"⬆ Проверить обновление (v{APP_VERSION})", f"⬆ Check for updates (v{APP_VERSION})"), self.do_self_update)
        link(c, tr("❓ FAQ", "❓ FAQ"), self._faq)
        link(c, "✈ Telegram  @zyngfast", lambda: __import__("webbrowser").open(TELEGRAM_URL), color=ACC)
        link(c, tr("ℹ О приложении", "ℹ About"), self._about)

    def _need_restart(self, win):
        """Показывает в окне настроек, что тема или язык применятся после перезапуска.

        Виджеты CustomTkinter берут цвета и подписи в момент создания, поэтому
        перекрасить и перевести уже собранное окно нельзя — проще пересоздать
        приложение целиком.
        """
        if getattr(self, "_restart_bar", None):
            return
        self._restart_bar = ctk.CTkFrame(win, fg_color=CARD, corner_radius=14,
                                         border_width=1, border_color=ACC)
        self._restart_bar.pack(fill="x", side="bottom", padx=10, pady=10)
        ctk.CTkLabel(self._restart_bar,
                     text=tr("Применится после перезапуска", "Applies after a restart"),
                     font=ctk.CTkFont(FONT, 12), text_color=TEXT).pack(side="left", padx=14, pady=10)

        def _go():
            if restart_app():
                self.root.after(200, self.on_close)
            else:
                self._flash(tr("Перезапусти приложение вручную",
                               "Please restart the app manually"), WARN)

        ctk.CTkButton(self._restart_bar, text=tr("Перезапустить", "Restart"),
                      width=120, height=30, corner_radius=12,
                      fg_color=ACC, hover_color=ACC_D, text_color="#ffffff",
                      font=ctk.CTkFont(FONT, 12, "bold"), command=_go).pack(side="right", padx=10, pady=8)

        # Окно закроют — ссылка на плашку должна умереть вместе с ним.
        win.protocol("WM_DELETE_WINDOW", lambda: (setattr(self, "_restart_bar", None), win.destroy()))

    def _reset_key(self):
        if not messagebox.askyesno(APP_NAME, tr("Удалить все ключи?", "Delete all keys?")): return
        self.links = []; self.manual_links = []; self.subs = []; self.sub_cache = {}
        self.sub_url = ""; self.active_tab = "all"; self.selected_idx = 0; self.render_servers()
        try: os.remove(CONFIG_FILE)
        except Exception: pass

    def _reconnect_note(self):
        if self.connected:
            self._flash(tr("Переподключись, чтобы применить", "Reconnect to apply"), WARN)

    def speed_test(self):
        """Реальный тест скорости загрузки через активное соединение (Мбит/с)."""
        if not self.connected:
            self._flash(tr("Сначала подключись", "Connect first"), WARN); return
        self._flash(tr("Замеряю скорость…", "Measuring speed…"), MUTED)
        def worker():
            try:
                import ssl
                proxy = f"http://127.0.0.1:{HTTP_PORT}"
                handler = urllib.request.ProxyHandler({"http": proxy, "https": proxy})
                ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
                opener = urllib.request.build_opener(handler, urllib.request.HTTPSHandler(context=ctx))
                url = "https://speed.cloudflare.com/__down?bytes=10000000"   # 10 МБ
                t0 = time.time(); got = 0
                with opener.open(urllib.request.Request(url, headers={"User-Agent": "Zyng"}), timeout=30) as r:
                    while True:
                        chunk = r.read(65536)
                        if not chunk: break
                        got += len(chunk)
                        if time.time() - t0 > 12: break     # хватит для оценки
                dt = max(0.001, time.time() - t0)
                mbps = (got * 8) / dt / 1_000_000
                self.root.after(0, lambda: self._flash(tr(f"⚡ Скорость: {mbps:.1f} Мбит/с", f"⚡ Speed: {mbps:.1f} Mbps"), OK))
            except Exception:
                self.root.after(0, lambda: self._flash(tr("Не удалось замерить скорость", "Could not measure speed"), DANGER))
        threading.Thread(target=worker, daemon=True).start()

    def _about(self):
        messagebox.showinfo(
            tr("О приложении", "About"),
            tr(f"Zyng VPN v{APP_VERSION}\n\nБыстрый VPN с обходом блокировок.\n"
               "VLESS (Reality), VMess, Trojan, Shadowsocks.\n\nTelegram: t.me/zyngfast",
               f"Zyng VPN v{APP_VERSION}\n\nA fast VPN that gets around blocking.\n"
               "VLESS (Reality), VMess, Trojan, Shadowsocks.\n\nTelegram: t.me/zyngfast"))

    def _stats(self):
        st = tr("Подключено", "Connected") if self.connected else tr("Отключено", "Disconnected")
        messagebox.showinfo(
            tr("Статистика", "Statistics"),
            tr(f"Статус: {st}\nСерверов: {len(self.links)}\n"
               f"SOCKS 127.0.0.1:{SOCKS_PORT} · HTTP :{HTTP_PORT}",
               f"Status: {st}\nServers: {len(self.links)}\n"
               f"SOCKS 127.0.0.1:{SOCKS_PORT} · HTTP :{HTTP_PORT}"))

    def _faq(self):
        messagebox.showinfo("FAQ", tr(
            "• ＋ или «Вставить» — добавь ключ/подписку.\n• Выбери страну слева.\n"
            "• Нажми круглую кнопку — подключение.\n• «Пинг» — отклик сервера.\n\nt.me/zyngfast",
            "• ＋ or the Add button — add a key or subscription.\n• Pick a country on the left.\n"
            "• Press the round button to connect.\n• “Ping” shows server response time.\n\nt.me/zyngfast"))

    def on_close(self):
        if self.connected: self.disconnect()
        self.root.destroy()


def restart_app():
    """Перезапускает приложение — тема и язык подхватятся при старте."""
    try:
        args = [sys.executable] if getattr(sys, "frozen", False) \
            else [sys.executable, os.path.abspath(sys.argv[0])]
        clean_env = {k: v for k, v in os.environ.items()
                     if not (k.startswith("_MEIPASS") or k.startswith("_PYI"))}
        kwargs = {"env": clean_env}
        if os.name == "nt":
            kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
        subprocess.Popen(args, **kwargs)
        return True
    except Exception:
        return False


def main():
    try:
        prefs = _early_prefs()
        apply_lang(prefs.get("lang", "system"))
        apply_theme(prefs.get("theme", "dark"))
        ctk.set_appearance_mode("light" if BG.upper() == "#F2F4F8" else "dark")
        ctk.set_default_color_theme("blue")
        root = ctk.CTk(); root.configure(fg_color=BG)
        ZyngApp(root); root.mainloop()
    except Exception:
        # Раньше здесь стояло молчание: ошибка писалась в файл, и всё. Из-за
        # этого сбой при запуске выглядел как «скачал, а оно не открывается» —
        # ни окна, ни объяснения. Лог оставляем, но причину показываем.
        text = ""
        try:
            import traceback
            text = traceback.format_exc()
            log = os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "zyng_error.log")
            with open(log, "a", encoding="utf-8") as f:
                f.write(text + "\n")
        except Exception:
            pass
        try:
            from tkinter import messagebox
            last = [l for l in text.strip().splitlines() if l.strip()][-1:] or ["неизвестная ошибка"]
            messagebox.showerror(
                APP_NAME,
                "Не удалось запустить приложение.\n\n"
                + last[0][:300]
                + "\n\nПодробности — в файле zyng_error.log рядом с программой.\n"
                  "Пришли его нам: t.me/zyngfast")
        except Exception:
            pass


if __name__ == "__main__":
    main()
