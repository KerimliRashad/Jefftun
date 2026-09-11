# Zyng iOS — Device Setup: Fix SIGKILL Crash

**SIGKILL crash происходит потому что VPN расширение не загружается на устройство.**

---

## Чек-лист перед запуском на устройстве

### 1. ✅ Проверь что ZyngTunnel есть в Bundle

В Xcode:
```
Select Zyng target → Build Phases → Copy Bundle Resources
```

**Должно быть:**
- ⚠️ НЕ должно быть: ZyngTunnel.appex, entitlements файлы

**Проверь:**
```
Select Zyng target → Build Phases → Embed App Extensions
```

**Должно быть:**
- ✅ ZyngTunnel.appex (это автоматически добавится)

### 2. ✅ Bundle ID точно совпадает

**Main App:**
```
Zyng target → General → Bundle Identifier = online.zyng.Zyng
```

**Extension:**
```
ZyngTunnel target → General → Bundle Identifier = online.zyng.Zyng.ZyngTunnel
```

⚠️ Вторая часть ДОЛЖНА быть: `.ZyngTunnel`

### 3. ✅ Team ID одинаковый

Оба таргета должны иметь один и тот же Team (Signing & Capabilities).

### 4. ✅ Capabilities включены на ОБОИХ

**Main App (Zyng):**
- Signing & Capabilities → Network Extension ✅
- Signing & Capabilities → Personal VPN ✅
- Signing & Capabilities → App Groups ✅

**Extension (ZyngTunnel):**
- Signing & Capabilities → Network Extension ✅
- Signing & Capabilities → App Groups ✅
- ⚠️ НЕ должно быть: Personal VPN

### 5. ✅ Entitlements правильные

**Zyng/Zyng.entitlements.plist:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.online.zyng.Zyng</string>
	</array>
	<key>com.apple.security.network-extension</key>
	<true/>
	<key>com.apple.security.personal-vpn</key>
	<true/>
</dict>
</plist>
```

**ZyngTunnel/ZyngTunnel.entitlements.plist:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.online.zyng.Zyng</string>
	</array>
	<key>com.apple.security.network-extension</key>
	<true/>
</dict>
</plist>
```

---

## Диагностика SIGKILL

### Шаг 1: Посмотри Console.app на устройстве

```
1. Mac: Console.app
2. Left panel: Выбери свой iPhone
3. Search: "Zyng"
4. Посмотри ошибки
```

**Ищи эти ошибки:**

| Ошибка | Причина | Решение |
|--------|---------|--------|
| "Invalid entitlements" | Entitlements не в правильном формате | Пересоздай .plist файлы |
| "No matching provisioning profile" | Профиль не совпадает с bundle ID | Regenerate на developer.apple.com |
| "Extension not found" | ZyngTunnel не в bundle | Добавь в Embed App Extensions |
| "Mismatch bundle identifier" | Bundle ID не совпадает | Проверь точное написание |

### Шаг 2: Проверь что расширение скомпилировалось

```bash
# После успешного build, проверь:
find ~/Library/Developer/Xcode/DerivedData -name "ZyngTunnel.appex" 2>/dev/null
```

Если не найдётся - расширение не скомпилировалось.

### Шаг 3: Проверь Bundle структуру

```bash
# Найди app bundle
cd ~/Library/Developer/Xcode/DerivedData
find . -name "Zyng.app" -type d | head -1

# Посмотри что внутри
ls -la Zyng.app/PlugIns/
```

**Должен быть:** `ZyngTunnel.appex/`

Если его нет - добавь в Build Phases → Embed App Extensions.

---

## Полная процедура Fix

Если ничего не сработало, делай так:

### 1. Clean Everything

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/Zyng*
```

### 2. В Xcode удали оба таргета из Signing & Capabilities

- Zyng: Remove all capabilities
- ZyngTunnel: Remove all capabilities

### 3. Добавь заново

**Zyng:**
1. Select target
2. Signing & Capabilities
3. `+ Capability`
4. Network Extension → Packet Tunnel (✓ enable)
5. Personal VPN (✓ enable)
6. App Groups → `group.online.zyng.Zyng`

**ZyngTunnel:**
1. Select target
2. Signing & Capabilities
3. `+ Capability`
4. Network Extension → Packet Tunnel (✓ enable)
5. App Groups → `group.online.zyng.Zyng`

### 4. Проверь Build Phases

**Zyng:**
- Embed Content → ZyngTunnel.appex ✅
- Copy Bundle Resources → Only Assets

**ZyngTunnel:**
- Link Binary with Libraries → All frameworks

### 5. Пересоздай provisioning profiles

На developer.apple.com:
1. Delete все profiles для `online.zyng.Zyng` и `online.zyng.Zyng.ZyngTunnel`
2. В Xcode: Signing & Capabilities → "Automatically manage signing"
3. Xcode автоматически создаст новые profiles

### 6. Clean Build Folder и пересобери

```
⌘⇧K (Clean)
⌘B (Build)
```

### 7. Запусти на устройстве и проверь Console.app

---

## Успешный старт выглядит так:

В Console.app должны быть логи:
```
🔵 Zyng: startTunnel called
✅ Zyng: VPN key received
✅ Zyng: Tunnel network settings applied successfully
📦 Zyng: Read X packet(s)
```

Если видишь эти логи - **всё работает!** ✅

---

## Если всё равно SIGKILL

Вероятно нужно:
1. Проверить что используешь Paid Developer Team (не Personal)
2. Удалить app с устройства и переустановить
3. Перезагрузить устройство
4. Создать новый iPhone Simulator и тестировать там (но помни: VPN не работает в симуляторе)
