# Zyng iOS — Quick Fix Checklist (5-10 minutes)

**Goal**: Get the app past App Store validation by ensuring entitlements are in the final binary.

---

## IMMEDIATE ACTIONS (Do These First)

### Action 1: Check Current Provisioning Profiles Status

Open Terminal and run:
```bash
# Find your provisioning profiles
ls ~/Library/MobileDevice/Provisioning\ Profiles/

# Check when each was created (the online.zyng.Zyng profiles)
# Note the oldest ones - these might not have the Network Extension entitlement
```

### Action 2: Remove Outdated Profiles

In Xcode:
1. **Xcode** → **Settings** → **Accounts** → Select your Apple ID
2. Click **Download Manual Profiles** (or click your Team and click "Manage Certificates")
3. This might help, but to be safe:
   - Go to **Preferences** → **Accounts** → Click your team
   - Click **Download Manual Profiles**
   - Restart Xcode

On developer.apple.com (parallel to above):
1. **Certificates, Identifiers & Profiles** → **Provisioning Profiles**
2. Delete the old provisioning profiles for:
   - `online.zyng.Zyng` (all variants: Debug, Release, Distribution)
   - `online.zyng.Zyng.ZyngTunnel` (all variants)
3. These will be auto-regenerated if using Automatic code signing

### Action 3: Fix Build Settings (The Critical Step)

**For BOTH Zyng and ZyngTunnel targets:**

1. Select target → **Build Settings**
2. Search for: `Code Signing Entitlements`
3. Expand the search result
4. For each configuration (Debug, Release, etc.):
   - **Zyng target** → set to: `Zyng/Zyng.entitlements`
   - **ZyngTunnel target** → set to: `ZyngTunnel/ZyngTunnel.entitlements`

**CRITICAL**: Make sure the value is a relative path (no $ symbols, no full path).

### Action 4: Clean and Rebuild

```bash
# In Terminal from project root:
rm -rf ~/Library/Developer/Xcode/DerivedData/*Zyng*
```

Then in Xcode:
- **Product** → **Clean Build Folder** (⌘⇧K)
- Close Xcode
- Reopen Xcode

### Action 5: Verify Entitlements in Binary

1. **Product** → **Archive**
2. In Organizer, right-click archive → **Show in Finder**
3. Right-click bundle → **Show Package Contents**
4. Open Terminal in this folder, run:

```bash
codesign -d --entitlements :- Zyng.app/Zyng | head -30
```

**Expected output should include:**
```
<key>com.apple.developer.networking.networkextension</key>
<true/>
```

If you see this, proceed to App Store submission. If you DON'T see it, go to Action 6.

---

## If Still Missing (Action 6: Manual Provisioning Profile Regeneration)

This is what was likely missed before:

### On developer.apple.com:

1. **Identifiers** page
2. Select `online.zyng.Zyng`
3. Click **Edit**
4. Scroll down to **Capabilities**
5. Find "Network Extension" - make sure it's checked ✓
6. Click **Save**
7. Do the same for `online.zyng.Zyng.ZyngTunnel` identifier

### Regenerate Provisioning Profiles:

1. **Provisioning Profiles** page
2. Find profiles named with `online.zyng.Zyng`:
   - Look for ones that are for App Store distribution
   - Look for ones for Ad Hoc distribution
   - Look for ZyngTunnel extension profiles
3. For EACH profile:
   - Click it
   - Click **Edit**
   - Click **Regenerate** button at bottom
   - Click **Done**
4. Download all updated profiles
5. Double-click them to import into Xcode (or drag into Xcode)

### Back in Xcode:

1. Select **Zyng** target
2. **General** tab
3. **Signing & Capabilities** section
4. Make sure "Automatically manage signing" is checked
5. Select correct Team (should be your Paid Developer Team, NOT Personal Team)
6. Do the same for **ZyngTunnel** target

---

## Verification Steps

### Before Archive:
```bash
# Run this after clicking Archive but before Export
# It checks if your code signing identity is correct
codesign -v -v ~/Library/Developer/Xcode/DerivedData/Zyng-*/Build/Products/Release-iphoneos/Zyng.app
```

### After Archive (Most Important):
```bash
# This DEFINITIVELY shows if entitlements are in the binary
codesign -d --entitlements :- /path/to/archived/Zyng.app/Zyng
```

**This MUST show:**
```
<key>com.apple.developer.networking.networkextension</key>
<true/>
<key>com.apple.security.network-extension</key>
<true/>
<key>com.apple.security.personal-vpn</key>
<true/>
```

And for ZyngTunnel (check the extension):
```bash
codesign -d --entitlements :- /path/to/archived/Zyng.app/PlugIns/ZyngTunnel.appex/ZyngTunnel
```

**Must show:**
```
<key>com.apple.developer.networking.networkextension</key>
<true/>
<key>com.apple.security.network-extension</key>
<true/>
```

---

## After Verification: App Store Submission

Once `codesign` shows the entitlements are present:

1. **Archive** again (clean archive)
2. **Product** → **Archive**
3. In Organizer: Right-click archive → **Validate App**
4. Select App Store Connect as distribution option
5. Let it validate
6. If validation passes → **Distribute App**
7. Select App Store Connect → Continue
8. Follow prompts to upload

---

## Troubleshooting: "Still Missing Entitlements"

If `codesign` output doesn't show the entitlements:

**Check 1: Wrong Team**
- Your App ID `online.zyng.Zyng` must be under a **PAID Developer Team**
- Not "Personal Team" (limited capabilities)
- Go to developer.apple.com → Account → Team Selection at top
- Make sure you're in a Paid Team, not Personal

**Check 2: Capabilities Not Enabled**
- Go to developer.apple.com → Identifiers
- Select `online.zyng.Zyng`
- Scroll to Capabilities section
- "Network Extension" should show as ✓ Enabled (green checkmark)
- If it shows "Not Available", your team doesn't support it

**Check 3: Provisioning Profile Not Updated**
```bash
# See when profile was created
security cms -D -i ~/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision | \
  grep -A2 -B2 "online.zyng.Zyng"

# If the date is before you enabled Network Extension on developer.apple.com,
# the profile is stale and must be regenerated
```

**Check 4: Xcode Cache**
```bash
# Full nuclear clean
rm -rf ~/Library/Developer/Xcode/DerivedData
rm -rf ~/Library/Caches/com.apple.dt.Xcode
killall -9 Xcode
# Restart Xcode
```

**Check 5: Build Settings Override**
- Make sure you didn't accidentally set "Code Signing Entitlements" to empty string or wrong path
- In Xcode → Build Settings, filter by target, search "Code Signing Entitlements"
- Value should be exactly: `Zyng/Zyng.entitlements` (for main app) or `ZyngTunnel/ZyngTunnel.entitlements`

---

## The Nuclear Option (Last Resort)

If nothing works:

1. **Delete everything**:
   - Delete App IDs: `online.zyng.Zyng` and `online.zyng.Zyng.ZyngTunnel` from developer.apple.com
   - Delete all related certificates and provisioning profiles
   - Delete derived data: `rm -rf ~/Library/Developer/Xcode/DerivedData/*`

2. **Start fresh**:
   - In Xcode, select target
   - **General** → **Signing & Capabilities**
   - "Automatically manage signing" toggle OFF then back ON
   - This forces Xcode to recreate everything from scratch

3. **Re-enable capabilities**:
   - On developer.apple.com, the new App IDs will be auto-created
   - Manually enable "Network Extension" for both App IDs
   - Regenerate provisioning profiles (developer.apple.com will show them as needing refresh)
   - Download profiles

4. **Verify again**:
   - Archive
   - `codesign -d --entitlements :-` check
   - Submit

---

## Success Indicators

✅ `codesign -d --entitlements :-` shows `com.apple.developer.networking.networkextension`
✅ App Store validation passes without entitlement errors
✅ Archive is accepted for distribution
✅ Next step: Submit for review

Once you see these indicators, you're ready to submit to App Store review!
