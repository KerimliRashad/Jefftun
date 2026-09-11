<p align="center"><img src="qipcall_client/jeff_banner.png" width="460" alt="JeffTUN"></p>
<h1 align="center">JeffTUN VPN</h1>
<p align="center">Быстрый VPN с обходом блокировок на ядре <b>xray-core</b>. Вставь ключ или ссылку-подписку — и подключайся.</p>

## Скачать

| Платформа | Ссылка |
|-----------|--------|
| 🪟 **Windows** (7 / 8 / 10 / 11) | [JeffTUN.exe](https://github.com/kerimlirashad/kerimlirashad/releases/download/jefftun/JeffTUN.exe) |
| 🐧 **Linux** (x64) | [JeffTUN-linux](https://github.com/kerimlirashad/kerimlirashad/releases/download/jefftun/JeffTUN-linux) |
| 📺 **TV Android** | [JeffTUN для Android TV](https://github.com/Happ-proxy/happ-android/releases/latest) — установи и вставь подписку JeffTUN |
| 🍎 **TV Apple** | [JeffTUN для Apple TV](https://apps.apple.com/app/happ-proxy-utility/id6504287215) — установи на Apple TV (tvOS) и вставь подписку JeffTUN |

Все релизы: **https://github.com/kerimlirashad/kerimlirashad/releases/tag/jefftun**

## Протоколы (Protocols)

![VLESS](https://img.shields.io/badge/VLESS-Reality-2ea043?style=for-the-badge)
![VMess](https://img.shields.io/badge/VMess-1f6feb?style=for-the-badge)
![Trojan](https://img.shields.io/badge/Trojan-8957e5?style=for-the-badge)
![Shadowsocks](https://img.shields.io/badge/Shadowsocks-db61a2?style=for-the-badge)
![SOCKS5](https://img.shields.io/badge/SOCKS5-e0574a?style=for-the-badge)
![WireGuard](https://img.shields.io/badge/WireGuard-f0883e?style=for-the-badge)
![Hysteria2](https://img.shields.io/badge/Hysteria2-sing--box-2ea043?style=for-the-badge)
![TUIC](https://img.shields.io/badge/TUIC-sing--box-2ea043?style=for-the-badge)

- **VLESS** — с поддержкой REALITY и XTLS Vision
- **VMess** — ws / grpc / tcp, TLS
- **Trojan** — TLS
- **Shadowsocks** — AEAD
- **SOCKS5** — с авторизацией и без
- **WireGuard** — на ядре xray
- **Hysteria2 / TUIC** — на ядре sing-box (встроено в приложение)

## Возможности

- 📋 **Подписки** — все форматы: base64, обычные списки, xray-JSON, sing-box-JSON, **Clash/Clash.Meta (YAML)**; несколько подписок вкладками; авто-обновление
- 🌍 **Список серверов** — флаги стран, живой пинг по каждому серверу
- ⚡ **Тест пинга и скорости** — пинг всех серверов + реальная скорость загрузки (Мбит/с)
- 🧭 **Умная маршрутизация** — локальные и RU-сайты напрямую, остальное через VPN
- 🖧 **Режим TUN** — VPN на всю систему (все приложения), на ядре sing-box
- 🔄 **Авто-обновление приложения** — обновляется внутри программы, без переустановки
- 🖥 **Системный прокси** — Windows / Linux
- 🚀 **Автозапуск** при входе в систему
- 🔒 **Приватность** — никакой сборки данных, всё хранится только на устройстве

## Как пользоваться

1. Скачай приложение под свою ОС (таблица выше).
2. Нажми **＋ Вставить ключ / подписку** и вставь `vless:// · vmess:// · trojan:// · ss:// · socks5:// · wireguard://` или ссылку-подписку `https://…`.
3. Выбери страну в списке и нажми круглую кнопку включения.

> ⚠️ Windows может показать **SmartScreen** («защитил ваш компьютер») — это нормально для новых программ без платной подписи. Нажми **«Подробнее» → «Выполнить в любом случае»**.

## 🐧 Установка на Linux (Ubuntu и другие)

**Через терминал (проще всего):**
```bash
# 1. Скачать
wget https://github.com/kerimlirashad/kerimlirashad/releases/download/jefftun/JeffTUN-linux
# 2. Сделать исполняемым
chmod +x JeffTUN-linux
# 3. Запустить
./JeffTUN-linux
```

**Через файловый менеджер (без терминала):**
1. Скачай файл **JeffTUN-linux** со страницы релизов.
2. ПКМ по файлу → **Свойства → Права (Permissions)** → поставь галочку **«Разрешить выполнение файла как программы»** (Allow executing file as program).
3. Двойной клик по файлу → **«Запустить» (Run)**.

**Возможные нюансы:**
- Если после запуска нет окна — запусти из терминала `./JeffTUN-linux`, чтобы увидеть сообщение.
- Нужен рабочий стол с GTK/GNOME (Ubuntu, Mint, Fedora и т.п.). Системный прокси включается автоматически через `gsettings` (GNOME). На других окружениях (KDE и др.) пропиши прокси вручную: **SOCKS5 `127.0.0.1:10808`** или **HTTP `127.0.0.1:10809`** в настройках сети.
- Иногда нужны системные библиотеки Tk: `sudo apt update && sudo apt install -y libtk8.6 libtcl8.6` (обычно уже стоят).
- Обновления ставятся внутри приложения — переустанавливать не нужно.

Telegram: **[@jeffvpn](https://t.me/jeffvpn)**
