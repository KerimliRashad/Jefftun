# Zyng iOS — Complete Xcode Project Setup Guide

This guide shows exactly what your Xcode project structure should look like and what files need to exist.

---

## Project Structure (What You Should Have)

```
Zyng.xcodeproj/
├── project.pbxproj
├── xcuserdata/
│   └── [your user]/xcuserstuff
└── xcshareddata/
    └── xcschemes/

Zyng/                           ← Main app group
├── Zyng.entitlements.plist
├── ContentView.swift
├── VPNController.swift
├── App.swift (or similar)
└── Assets.xcassets

ZyngTunnel/                     ← VPN Extension target
├── ZyngTunnel.entitlements.plist
├── PacketTunnelProvider.swift
├── Info.plist (or may not exist in modern Xcode)
└── (usually no other files)

.gitignore
README.md
```

---

## Required Files Content

### 1. Zyng/Zyng.entitlements.plist

**MUST BE EXACTLY THIS** (copy-paste to be safe):

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

**Key Points:**
- ✅ Has `com.apple.security.personal-vpn` (main app only)
- ✅ Has `com.apple.security.network-extension`
- ✅ Has app group: `group.online.zyng.Zyng`
- ❌ Does NOT have `com.apple.developer.networking.networkextension` (that comes from provisioning profile)

### 2. ZyngTunnel/ZyngTunnel.entitlements.plist

**MUST BE EXACTLY THIS**:

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

**Key Points:**
- ✅ Does NOT have `com.apple.security.personal-vpn` (extensions can't have this)
- ✅ Has `com.apple.security.network-extension`
- ✅ Same app group as main app: `group.online.zyng.Zyng`

---

## Xcode Build Settings

### For BOTH Zyng and ZyngTunnel targets:

**Build Settings tab**, search for these values:

| Setting | Value | Zyng | ZyngTunnel |
|---------|-------|------|-----------|
| **Code Signing Entitlements** | Relative path | `Zyng/Zyng.entitlements` | `ZyngTunnel/ZyngTunnel.entitlements` |
| **Code Signing Identity** | Any value | `Apple Development` | `Apple Development` |
| **Code Signing Style** | Any value | `Automatic` | `Automatic` |
| **Bundle Identifier** | Your ID | `online.zyng.Zyng` | `online.zyng.Zyng.ZyngTunnel` |
| **Product Name** | Shown in UI | `Zyng` | `ZyngTunnel` |

**CRITICAL**: "Code Signing Entitlements" MUST be a relative path:
- ✅ `Zyng/Zyng.entitlements`
- ❌ `$(SRCROOT)/Zyng/Zyng.entitlements`
- ❌ `/Users/name/Projects/Zyng/Zyng.entitlements`
- ❌ `./Zyng/Zyng.entitlements`

---

## Xcode Build Phases

### For Zyng target → Build Phases:

**Copy Bundle Resources** should contain:
- ✅ Assets.xcassets
- ✅ Other images/resources

Should NOT contain:
- ❌ `Zyng.entitlements.plist` (remove if present!)

**Link Binary with Libraries** should contain:
- ✅ Foundation.framework
- ✅ SwiftUI.framework
- ✅ NetworkExtension.framework
- ✅ Combine.framework

### For ZyngTunnel target → Build Phases:

**Copy Bundle Resources** should contain:
- ✅ Nothing (or minimal resources)

Should NOT contain:
- ❌ `ZyngTunnel.entitlements.plist` (remove if present!)

**Link Binary with Libraries** should contain:
- ✅ Foundation.framework
- ✅ NetworkExtension.framework

**Embed Content** (if present):
- ✅ Any frameworks you're embedding (like libXray.xcframework)

---

## Xcode Signing & Capabilities

### For Zyng target → Signing & Capabilities tab:

**This section is CRITICAL. Must have:**

1. **Team**: Your Paid Developer Team (not Personal Team)
2. **Bundle Identifier**: `online.zyng.Zyng`
3. **Automatically manage signing**: Toggle ON
4. **Capabilities** (should auto-appear):
   - ✅ App Groups
     - Container: `group.online.zyng.Zyng`
   - ✅ Network Extension
     - Packet Tunnel: checked ✓
   - ✅ Personal VPN: checked ✓

### For ZyngTunnel target → Signing & Capabilities tab:

**Same as above, except:**

1. **Team**: Same as main app
2. **Bundle Identifier**: `online.zyng.Zyng.ZyngTunnel`
3. **Automatically manage signing**: Toggle ON
4. **Capabilities**:
   - ✅ App Groups
     - Container: `group.online.zyng.Zyng` (same as main app!)
   - ✅ Network Extension
     - Packet Tunnel: checked ✓
   - ❌ Personal VPN: NOT present (don't add)

---

## Bundle ID Rules (Critical!)

Your bundle IDs MUST follow this pattern:

```
Main App:     online.zyng.Zyng
Extension:    online.zyng.Zyng.ZyngTunnel
                         ↑
                    Must start with main app ID
```

**Why**: App Groups and container access depend on this hierarchy.

---

## Apple Developer Portal Setup

### Create App IDs

1. Go to developer.apple.com → **Certificates, Identifiers & Profiles**
2. **Identifiers** → Click **+** button
3. Create TWO identifiers:

**First (Main App):**
- Name: `Zyng App`
- Bundle ID: `online.zyng.Zyng` (explicit)
- Capabilities:
  - ✅ App Groups
  - ✅ Network Extension (with Packet Tunnel)
  - ✅ Personal VPN

**Second (Extension):**
- Name: `Zyng Tunnel Extension`
- Bundle ID: `online.zyng.Zyng.ZyngTunnel` (explicit)
- Capabilities:
  - ✅ App Groups
  - ✅ Network Extension (with Packet Tunnel)
  - ❌ Personal VPN (don't add!)

### Create Provisioning Profiles

For each identifier, create provisioning profile(s):
- Development (for testing on device)
- App Store (for submission)

**For each profile:**
1. Select the App ID
2. Select your certificates
3. Select your devices (if development profile)
4. Name: e.g., `Zyng App Store Profile`
5. Download

Then import into Xcode (double-click or drag into Xcode window).

---

## Verification Checklist

Before attempting to archive:

- [ ] Both entitlements .plist files exist in project
- [ ] Entitlements .plist files have correct XML content (copy-paste from above)
- [ ] Build Settings "Code Signing Entitlements" has relative path for both targets
- [ ] Entitlements files are NOT in Copy Bundle Resources
- [ ] Both targets have correct Bundle IDs
- [ ] Both targets have same Team selected
- [ ] Signing & Capabilities shows all required capabilities
- [ ] On developer.apple.com, both App IDs have Network Extension capability enabled
- [ ] Provisioning profiles were regenerated AFTER enabling Network Extension
- [ ] Provisioning profiles are imported in Xcode

---

## Quick Verification Before Archive

Run this in Terminal from your project root:

```bash
# Check if entitlements files exist
test -f Zyng/Zyng.entitlements && echo "✅ Main app entitlements found" || echo "❌ Missing"
test -f ZyngTunnel/ZyngTunnel.entitlements && echo "✅ Tunnel entitlements found" || echo "❌ Missing"

# Check content (should be valid XML)
plutil -p Zyng/Zyng.entitlements 2>&1 | head -5
plutil -p ZyngTunnel/ZyngTunnel.entitlements 2>&1 | head -5
```

Expected output:
```
✅ Main app entitlements found
✅ Tunnel entitlements found
[valid XML shown]
```

---

## After Archive - The Real Verification

Only this verification matters for App Store submission:

```bash
# Navigate to archived app
cd ~/Library/Developer/Xcode/DerivedData/Zyng-*/Build/Products/Release-iphoneos/

# Check main app entitlements
codesign -d --entitlements :- Zyng.app/Zyng | grep "networking.networkextension" && \
  echo "✅ Main app has networkextension entitlement" || \
  echo "❌ MISSING"

# Check extension entitlements  
codesign -d --entitlements :- Zyng.app/PlugIns/ZyngTunnel.appex/ZyngTunnel | grep "networking.networkextension" && \
  echo "✅ Extension has networkextension entitlement" || \
  echo "❌ MISSING"
```

If you see both ✅, you're ready to submit!

---

## Common Issues and Fixes

| Issue | Cause | Fix |
|-------|-------|-----|
| "Missing Entitlement" error on submission | Provisioning profile doesn't have entitlement | Regenerate provisioning profile on developer.apple.com |
| Build fails with "Entitlements not found" | Wrong path in Build Settings | Use relative path: `Zyng/Zyng.entitlements` |
| "Personal VPN" capability greyed out | Using Personal Team account | Switch to Paid Developer Team |
| Entitlements exist but not in binary | Entitlements in Copy Bundle Resources | Remove from Copy Bundle Resources |
| Bundle ID mismatch | Extension ID doesn't start with main app ID | Make it `online.zyng.Zyng.ZyngTunnel` |

---

## Summary

The most important things:

1. **Entitlements .plist files** must exist with correct content
2. **Build Settings** must point to these files using relative paths
3. **Capabilities** must be enabled on both developer.apple.com App IDs
4. **Provisioning profiles** must be regenerated after enabling capabilities
5. **Final verification** with `codesign` before submission

Get all 5 right, and App Store submission will succeed!
