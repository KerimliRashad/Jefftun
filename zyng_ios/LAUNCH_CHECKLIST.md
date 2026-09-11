# Zyng iOS — Complete Launch Checklist

**Этот гайд - финальная инструкция для успешного запуска VPN на устройстве.**

Время: ~30 минут. Следуй в порядке.

---

## ФАЗА 1: Code (5 минут)

- [x] ✅ **VPNController.swift** - Updated (zero Swift 6 warnings)
- [x] ✅ **PacketTunnelProvider.swift** - Updated (zero Swift 6 warnings)
- [x] ✅ **Code compiles** - No build errors

**Что делать если есть ошибки:**
```
⌘⇧K (Clean Build Folder)
⌘B (Build)
```

---

## ФАЗА 2: Bundle ID (5 минут)

### Main App Bundle ID

```
Xcode → Select Zyng target → General → Bundle Identifier
```

**Должно быть РОВНО:**
```
online.zyng.Zyng
```

⚠️ Без пробелов, без заглавных букв в конце (кроме Z в начале).

### Extension Bundle ID

```
Xcode → Select ZyngTunnel target → General → Bundle Identifier
```

**Должно быть РОВНО:**
```
online.zyng.Zyng.ZyngTunnel
```

Тест: Если в main app вставить `online.zyng.Zyng`, то в extension АВТОМАТИЧЕСКИ будет `online.zyng.Zyng.ZyngTunnel` - не трогай!

---

## ФАЗА 3: Team Selection (2 минуты)

**ОБА таргета должны иметь ОДИН и ТОТ ЖЕ Team:**

```
Zyng target → Signing & Capabilities → Team: [Твой Team]
ZyngTunnel target → Signing & Capabilities → Team: [ТОЖЕ же Team]
```

⚠️ **ВАЖНО:** Должен быть **Paid Developer Team** ($99/год), не Personal Team.

Personal Team НЕ поддерживает VPN capabilities!

---

## ФАЗА 4: Capabilities (10 минут)

### Zyng Target (Main App)

```
Zyng → Signing & Capabilities
```

Нужны 3 capability:

#### 1. Network Extension
- Click `+ Capability`
- Select `Network Extension`
- Packet Tunnel: ✓ Enable

#### 2. Personal VPN
- Click `+ Capability`
- Select `Personal VPN`
- ✓ Should appear

#### 3. App Groups
- Click `+ Capability`
- Select `App Groups`
- Add: `group.online.zyng.Zyng`

### ZyngTunnel Target (Extension)

```
ZyngTunnel → Signing & Capabilities
```

Нужны 2 capability:

#### 1. Network Extension
- Click `+ Capability`
- Select `Network Extension`
- Packet Tunnel: ✓ Enable

#### 2. App Groups
- Click `+ Capability`
- Select `App Groups`
- Add: `group.online.zyng.Zyng` (**SAME as main app**)

⚠️ **НЕ добавляй** Personal VPN к extension!

---

## ФАЗА 5: Entitlements Files (3 минуты)

### Check Zyng/Zyng.entitlements.plist

Должен существовать и содержать:
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.online.zyng.Zyng</string>
</array>
<key>com.apple.security.network-extension</key>
<true/>
<key>com.apple.security.personal-vpn</key>
<true/>
```

### Check ZyngTunnel/ZyngTunnel.entitlements.plist

Должен существовать и содержать:
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.online.zyng.Zyng</string>
</array>
<key>com.apple.security.network-extension</key>
<true/>
```

---

## ФАЗА 6: Build Settings (2 минуты)

### Zyng Target → Build Settings

Search: `Code Signing Entitlements`

**Must be:** `Zyng/Zyng.entitlements.plist`

### ZyngTunnel Target → Build Settings

Search: `Code Signing Entitlements`

**Must be:** `ZyngTunnel/ZyngTunnel.entitlements.plist`

---

## ФАЗА 7: Build Phases (3 минуты)

### Zyng Target → Build Phases

**Expand: Embed App Extensions**
- Should contain: `ZyngTunnel.appex`
- If missing → Add → Select ZyngTunnel.appex

**Expand: Copy Bundle Resources**
- Should NOT contain: Any .entitlements files
- Should contain: Assets.xcassets

### ZyngTunnel Target → Build Phases

**Copy Bundle Resources**
- Should NOT contain: ZyngTunnel.entitlements.plist

**Link Binary with Libraries**
- Should contain: NetworkExtension.framework, Foundation.framework

---

## ФАЗА 8: Clean & Build

```bash
# Terminal

# Clean everything
rm -rf ~/Library/Developer/Xcode/DerivedData/*Zyng*

# In Xcode
⌘⇧K (Clean Build Folder)
⌘B (Build)
```

**Wait for:** "Build Complete" ✅

---

## ФАЗА 9: Test on Device

1. **Connect iPhone via USB**
2. **Select iPhone as build target** (dropdown at top)
3. **⌘R (Run)**
4. **Wait for app to launch** on device

---

## ФАЗА 10: First Launch

On iPhone:
```
Settings → Allow Zyng to configure VPN? → Allow
```

If this popup doesn't appear → something is wrong (see Console.app)

---

## ФАЗА 11: Check Console.app Logs

```
Mac: Console.app
Left sidebar: Select your iPhone
Search: "Zyng"
```

**Expected logs:**
```
🔵 Zyng: startTunnel called
✅ Zyng: VPN key received
✅ Zyng: Tunnel network settings applied successfully
📦 Zyng: Read X packet(s)
```

**If you see these → SUCCESS!** ✅

**If you see errors → Read CONSOLE_DEBUG.md**

---

## ФАЗА 12: Test VPN Connection

In Zyng app:
1. Select a VPN server (paste VLESS/VMESS/etc key)
2. Tap "Connect"
3. Wait ~2 seconds
4. Check Console.app for logs

---

## Common Problems During Launch

| Problem | Solution |
|---------|----------|
| Build fails | Read build error, usually Bundle ID or entitlements mismatch |
| App launches but crashes | Check Console.app - see CONSOLE_DEBUG.md |
| No "Allow VPN" popup | Entitlements not signed into binary - regenerate profiles |
| "permission denied" error | Missing Personal VPN capability |
| Extension not found | Not in Embed App Extensions - add it |

---

## Verification Checklist

Before declaring "success", verify:

- [ ] Bundle ID: Main = `online.zyng.Zyng`, Extension = `online.zyng.Zyng.ZyngTunnel`
- [ ] Same Team for both targets
- [ ] 3 capabilities on main app (Network Extension, Personal VPN, App Groups)
- [ ] 2 capabilities on extension (Network Extension, App Groups)
- [ ] Entitlements files exist and have correct content
- [ ] Build Settings have correct paths to .plist files
- [ ] Build Phases: Zyng has "Embed App Extensions" with ZyngTunnel.appex
- [ ] Code compiles with zero errors
- [ ] App runs on device
- [ ] Console.app shows expected logs

---

## Next Steps After Success

Once Console.app shows the logs above:

1. **Integrate libXray** - See LIBXRAY_INTEGRATION.md
2. **Test VPN protocols** - Use VLESS/VMESS/TROJAN keys
3. **Add UI for server selection** - Currently just console testing
4. **Submit to App Store** - See ENTITLEMENTS_FIX.md

---

## Need Help?

1. **Check Console.app** - 80% of issues are visible there
2. **Read DEVICE_SETUP.md** - Complete configuration guide
3. **Read CONSOLE_DEBUG.md** - Error message explanations
4. **Verify all items in this checklist** - Most problems are misconfiguration

Good luck! You've got this! 🚀
