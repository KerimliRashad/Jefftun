# Zyng iOS — Console.app Debugging Guide

Когда VPN app крашится на устройстве, **Console.app** покажет точную причину.

---

## Как открыть Console.app и фильтровать логи

### Шаг 1: Запусти Console.app
```
Cmd+Space → Console.app → Enter
```

### Шаг 2: Выбери iPhone в левой панели
```
Left sidebar → Твой iPhone
```

### Шаг 3: Включи исходные процессы (если нужно)
```
Вверху справа: Action menu (три точки) → Include Info Messages ✓
```

### Шаг 4: Добавь фильтр
```
Вверху справа: search box → Напиши "Zyng"
```

---

## Таблица ошибок и решений

### ❌ "entitlement not found"

**Сообщение:**
```
[Zyng] com.apple.security.network-extension entitlement not found
```

**Причина:** Entitlements не в binary

**Решение:**
1. On developer.apple.com → Identifiers → Check "Network Extension" is enabled
2. Regenerate provisioning profile
3. Clean Build Folder (⌘⇧K)
4. Rebuild

---

### ❌ "No matching provisioning profile"

**Сообщение:**
```
No matching provisioning profile found for bundle identifier 'online.zyng.Zyng'
```

**Причина:** Bundle ID не совпадает с provisioning profile

**Решение:**
1. Проверь Bundle ID: Zyng target → General → Bundle Identifier
2. Должна быть РОВНО: `online.zyng.Zyng`
3. На developer.apple.com создай новый profile для этого ID
4. Download в Xcode

---

### ❌ "Extension not found" или "dyld: Library not loaded"

**Сообщение:**
```
[Zyng] Extension not found
dyld: Library not loaded: @rpath/ZyngTunnel.appex
```

**Причина:** ZyngTunnel расширение не bundled в app

**Решение:**
1. Zyng target → Build Phases
2. **Embed App Extensions** → должно быть ZyngTunnel.appex
3. Если там его нет → Add → Select ZyngTunnel.appex
4. Clean Build Folder и пересобери

---

### ❌ "Invalid Code Signature"

**Сообщение:**
```
Error: invalid code signature (code or signature have been modified)
```

**Причина:** Проблема с code signing

**Решение:**
1. Zyng target → Signing & Capabilities
2. Автоматический signing отключи и включи заново
3. Выбери correct Team
4. Clean Build Folder и пересобери

---

### ❌ "Permission denied" для VPN

**Сообщение:**
```
NEVPNErrorDomain error -1
permission denied
```

**Причина:** VPN configuration не имеет необходимых permissions

**Решение:**
1. На устройстве: Settings → VPN & Device Management
2. Если есть старые Zyng configurations → Delete их
3. Удали app с устройства
4. Переустанови app
5. При первом запуске iOS покажет "Allow VPN" → Tap Allow

---

### ⚠️ "Task-isolated 'completion' risks causing data races"

**Это не крах!** Это Swift 6 warning на Mac, не на устройстве.

**Решение:** Это уже исправлено в новом коде (нет нужно ничего делать).

---

### ❌ "The operating system terminated the process" (SIGKILL)

**Это самая частая ошибка.** Означает что iOS принудительно завершил процесс.

**Вероятные причины:**

| Причина | Признак | Решение |
|---------|---------|--------|
| Плохая конфигурация VPN | Нет логов вообще | Проверь DEVICE_SETUP.md пункт 1-5 |
| Расширение не загружается | Логи обрываются на startTunnel | Проверь Bundle структуру (см. ниже) |
| Watchdog timeout | Логи идут ~10 сек потом крах | Упрости PacketTunnelProvider (сейчас в норме) |
| Отсутствуют capabilities | Логи о entitlements ошибки | Regenerate provisioning profiles |

---

## Проверка Bundle структуры через Console

```bash
# В Terminal на Mac:

# 1. Найди app
find ~/Library/Developer/Xcode/DerivedData -name "Zyng.app" -type d | head -1

# 2. Посмотри что внутри
ls -la "путь_к_app/PlugIns/"

# Должно быть: ZyngTunnel.appex
```

Если ZyngTunnel.appex там не появилась → see Embed App Extensions в DEVICE_SETUP.md

---

## Успешные логи выглядят так:

```
[Zyng] Launching process...
[Zyng] Process started
🔵 Zyng: startTunnel called
✅ Zyng: VPN key received (length: 123)
✅ Zyng: Tunnel network settings applied successfully
📦 Zyng: Read 42 packet(s)
```

Если видишь эти логи → **VPN работает!** ✅

---

## Тестирование после исправления

1. **На устройстве:**
   - Открой Settings → VPN & Device Management
   - Должна быть "Zyng VPN" configuration

2. **В app:**
   - Выбери server
   - Tap Connect
   - iOS покажет "Allow" popup → Tap Allow

3. **В Console.app:**
   - Должны появиться логи выше
   - Если ошибок - они будут красные

---

## Если всё равно не работает

Дай скриншот всех логов из Console.app и:
1. Напиши какие РОВНО логи видишь
2. Напиши точную ошибку если есть
3. Проверь что сделал все шаги из DEVICE_SETUP.md

Мне будет легче диагностировать.
