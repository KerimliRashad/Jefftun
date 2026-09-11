# Zyng iOS — Fixing Missing Entitlements in App Store Binary

## Problem
When submitting to App Store, getting error:
```
Missing Entitlement. The bundle 'Zyng.app' is missing entitlement 
'com.apple.developer.networking.networkextension'
```

Even though:
- Entitlements .plist files are correctly configured
- Build Settings point to the right .plist files
- Provisioning profiles contain these entitlements

**Root Cause**: The entitlements specified in .plist files are NOT being merged into the final code signature during the Archive → Export process.

---

## Solution Checklist

### Step 1: Verify Entitlements Files Exist and Are Correct

**Main App Entitlements** (`Zyng/Zyng.entitlements`):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.online.zyng.Zyng</string>
    </array>
    <key>com.apple.security.personal-vpn</key>
    <true/>
    <key>com.apple.security.network-extension</key>
    <true/>
</dict>
</plist>
```

**VPN Extension Entitlements** (`ZyngTunnel/ZyngTunnel.entitlements`):
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

**Key Difference**: Main app has `com.apple.security.personal-vpn`, extension does NOT.

### Step 2: Fix Build Settings Path Issues

This is the MOST COMMON cause of the problem.

**For Zyng Target:**
1. Select **Zyng** target → **Build Settings**
2. Search for "Code Signing Entitlements"
3. Set the value to: `Zyng/Zyng.entitlements`
   - ⚠️ NOT `$(SRCROOT)/Zyng/Zyng.entitlements`
   - ⚠️ NOT full path like `/Users/.../Zyng/Zyng.entitlements`
   - ✅ Use RELATIVE path: `Zyng/Zyng.entitlements`
4. Make sure this is set for ALL configurations (Debug, Release, etc.)

**For ZyngTunnel Target:**
1. Select **ZyngTunnel** target → **Build Settings**
2. Search for "Code Signing Entitlements"
3. Set the value to: `ZyngTunnel/ZyngTunnel.entitlements`
   - Same rule: relative path, no $(SRCROOT)

### Step 3: Verify Build Phases

**For Zyng target:**
- Go to **Build Phases**
- Expand **Copy Bundle Resources**
- ⚠️ Entitlements files should NOT be in Copy Bundle Resources
- Remove them if they're there (entitlements are for code signing only, not bundled)

**For ZyngTunnel target:**
- Same check - no entitlements in Copy Bundle Resources

### Step 4: Clean Everything

In Xcode:
1. **Product** → **Clean Build Folder** (⌘⇧K)
2. **Product** → **Delete Derived Data**
   - Hold ⌘, go to Organizer → Projects tab
   - Select Zyng → Delete
3. Close Xcode completely
4. Delete `/Library/Developer/Xcode/DerivedData/*Zyng*`
5. Restart Xcode

### Step 5: Archive and Check the Binary

1. **Product** → **Archive**
2. In Organizer window, select the archive
3. Right-click → **Show in Finder**
4. Right-click archive → **Show Package Contents**
5. Navigate: `Products/Applications/Zyng.app/`
6. Run in Terminal:
```bash
codesign -d --entitlements :- /path/to/Zyng.app
```

**Expected output should contain:**
```
<key>com.apple.developer.networking.networkextension</key>
<true/>
<key>com.apple.security.network-extension</key>
<true/>
<key>com.apple.security.personal-vpn</key>
<true/>
```

If you see `com.apple.security.network-extension` but NOT `com.apple.developer.networking.networkextension`, that's your problem.

### Step 6: Fix Provisioning Profile Issues

The `com.apple.developer.networking.networkextension` entitlement is automatically added by Apple IF:
1. You've enabled "Network Extension" capability for the target on developer.apple.com
2. Your provisioning profile was regenerated AFTER enabling this capability

**On developer.apple.com:**
1. Go to **Identifiers**
2. Find **online.zyng.Zyng** (main app ID)
3. Edit → Capabilities → Enable "Network Extension"
4. Go to **Provisioning Profiles**
5. Find the provisioning profile for **online.zyng.Zyng** (app distribution or development)
6. Click **Edit** → Scroll to bottom → Click **Regenerate**
7. Download the new profile and import into Xcode

**Do the same for ZyngTunnel:**
1. Edit **online.zyng.Zyng.ZyngTunnel** App ID
2. Enable "Network Extension" capability
3. Regenerate its provisioning profile
4. Download and import

### Step 7: Key Discovery About Export/Distribution

When using **Archive → Export for App Store Distribution**, Xcode does NOT use your entitlements .plist files from Build Settings. Instead, it uses ONLY what's embedded in the provisioning profile.

**This means:**
1. The provisioning profile MUST have these entitlements baked in
2. If the provisioning profile doesn't have them, Archive/Export won't add them
3. That's why even with correct .plist files, you get the error

**Verification:**
```bash
# Extract and view provisioning profile
security cms -D -i /path/to/provisioning_profile.mobileprovision | plutil -p -
```

Look for section with `<key>Entitlements</key>` and inside it you MUST see:
```xml
<key>com.apple.developer.networking.networkextension</key>
<true/>
<key>com.apple.security.network-extension</key>
<true/>
```

---

## Why This Happens

1. **Local Development**: When you run on a device from Xcode, it uses entitlements from your .plist file + provisioning profile
2. **Archive/Export**: When creating an archive for distribution, Xcode uses ONLY what's in the provisioning profile
3. **Provisioning Profile Generation**: Apple only adds `com.apple.developer.networking.networkextension` if the App ID has "Network Extension" capability enabled
4. **Timing Issue**: If you enabled Network Extension capability AFTER creating the provisioning profile, the profile doesn't have it

---

## Complete Fix Process (Summary)

1. ✅ Verify entitlements .plist files are correct XML
2. ✅ Fix Build Settings paths (use relative paths: `Zyng/Zyng.entitlements`)
3. ✅ Remove entitlements from Copy Bundle Resources
4. ✅ Clean Xcode derived data
5. ✅ Enable Network Extension capability on developer.apple.com
6. ✅ Regenerate provisioning profiles
7. ✅ Download and import new profiles into Xcode
8. ✅ Clean build folder
9. ✅ Archive and verify using `codesign` command
10. ✅ Export for App Store Distribution

---

## Testing

**Before Archive:**
```bash
# Select the archived app
codesign -d --entitlements :- /path/to/Zyng.app
```

**Expected to see:**
```
Executable=/path/to/Zyng.app/Zyng
Entitlements dict(
    [0] <key>com.apple.developer.networking.networkextension</key>
    [0] <true/>
    ...
)
```

---

## If Still Not Working

1. **Check Team ID**: Make sure you're using a **Paid Developer Account**, not Personal Team
   - Personal Team cannot request Network Extension capability
   - Must be Paid ($99/year) or Organization account

2. **Regenerate Identifiers**: Sometimes Apple's system needs a full refresh
   - On developer.apple.com, go to Identifiers
   - Delete the app IDs (or just rebuild)
   - Create them fresh: `online.zyng.Zyng` and `online.zyng.Zyng.ZyngTunnel`
   - Enable Network Extension for both
   - Create new provisioning profiles

3. **Double-check Bundle IDs**: In Xcode, make sure:
   - Zyng target → Signing & Capabilities → Bundle Identifier = `online.zyng.Zyng`
   - ZyngTunnel target → Signing & Capabilities → Bundle Identifier = `online.zyng.Zyng.ZyngTunnel`

4. **Contact Apple**: If all above fails, App Store Review support can clarify why your provisioning profile isn't receiving the entitlement
