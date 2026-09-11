# Zyng — iOS VPN

## Запуск с нуля

```bash
mkdir -p ~/Developer
cd ~/Developer
git clone https://github.com/KerimliRashad/KerimliRashad.git
cd KerimliRashad/zyng
./setup.sh
open Zyng.xcodeproj
```

Дальше в Xcode один раз:

1. Таргет **Zyng** → Signing & Capabilities → **Team** = твой платный аккаунт
2. Таргет **ZyngTunnel** → Signing & Capabilities → **тот же Team**
3. `⌘R`

Всё. Capabilities, entitlements, вложение расширения, Bundle ID — уже настроены.

---

## Почему именно так

Раньше проект собирался в Xcode вручную, и каждый раз что-то расходилось:
пропадали `.entitlements`, слетали capabilities, ломались пути. Теперь весь
проект описан в `project.yml`, а `.xcodeproj` генерируется из него командой.

**Если Xcode-проект сломается — просто пересоздай его:**

```bash
rm -rf Zyng.xcodeproj && ./setup.sh
```

Это безопасно. Твой код лежит в `Zyng/` и `ZyngTunnel/` и не трогается.

---

## Не клади проект на Рабочий стол

macOS защищает `~/Desktop`, `~/Documents` и папки iCloud. Xcode не может там
создавать файлы — отсюда ошибка **«Operation not permitted (1)»**, из-за которой
не создавались entitlements.

Держи проект в `~/Developer`. `setup.sh` проверяет это и предупредит.

---

## Что уже работает

- UI: список серверов, импорт ключей, подключение, таймер сессии, пинг
- Ключи: VLESS, VMESS, Trojan, Shadowsocks, Hysteria2, TUIC, SOCKS
- Транспорты: tcp, ws, grpc, http/h2, httpupgrade, quic
- Подписки: обновление по ссылке, трафик и срок из заголовков панели
- Ядро sing-box внутри расширения — трафик реально ходит через прокси
- Live Activity и переключатель в Пункте управления (iOS 18)

---

## Как тестировать

### На iPhone из Xcode — единственный способ проверить сам VPN

1. Подключи iPhone кабелем к MacBook, на телефоне разреши «Доверять компьютеру»
2. В Xcode вверху рядом с кнопкой ▶︎ выбери свой iPhone вместо симулятора
3. `⌘R`
4. Первый запуск: на iPhone → Настройки → Основные → VPN и управление
   устройством → твой профиль разработчика → **Доверять**

Дальше можно отвязать кабель: **Window → Devices and Simulators → выбери
iPhone → галочка «Connect via network»**. После этого `⌘R` ставит сборку по
Wi-Fi, телефон достаточно держать в той же сети.

Логи расширения в консоли Xcode не видны — расширение это отдельный процесс.
Смотреть их так: **Console.app** на Mac → слева выбери iPhone → в поиске
`ZyngTunnel`. Все наши сообщения помечены `🔵 Zyng`.

### В симуляторе — только интерфейс, без подключения

Симулятор запустится (`Libcore.xcframework` собирается и под `iossimulator`),
но кнопка подключения выдаст ошибку: **NetworkExtension в симуляторе не
работает**, packet tunnel там не поднимается в принципе. Годится, чтобы
посмотреть вёрстку, список серверов и настройки — не более.

### Прямо на macOS — сейчас нельзя

Для запуска приложения как маковского (Mac Catalyst) нужен срез
`maccatalyst` в `Libcore.xcframework`, а `build-core.sh` собирает только
`ios,iossimulator` — gomobile другого и не умеет. Плюс NetworkExtension на
macOS требует отдельного разрешения от Apple. Так что тестировать надо на
живом iPhone.

---

## Структура

```
zyng/
├── project.yml          описание проекта (заменяет ручную настройку в Xcode)
├── setup.sh             генерация Zyng.xcodeproj
├── Zyng/                приложение
│   ├── ZyngApp.swift
│   ├── ContentView.swift
│   ├── VPNController.swift
│   ├── Zyng.entitlements
│   └── Info.plist
└── ZyngTunnel/          расширение (packet tunnel)
    ├── PacketTunnelProvider.swift
    ├── ZyngTunnel.entitlements
    └── Info.plist
```

## Идентификаторы

| | |
|---|---|
| Приложение | `online.zyng.Zyng` |
| Расширение | `online.zyng.Zyng.ZyngTunnel` |
| App Group | `group.online.zyng.Zyng` |

Bundle ID расширения обязан начинаться с Bundle ID приложения.
