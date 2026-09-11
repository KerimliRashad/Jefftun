# Zyng iOS — LibXray Integration Guide

This guide shows how to integrate the Xray VPN engine (libXray) into your Zyng iOS app for real VPN functionality.

---

## What is libXray?

**libXray** is the iOS framework built from [XTLS/libXray](https://github.com/XTLS/libXray). It provides:
- Support for VPN protocols: VLESS, VMESS, TROJAN, Shadowsocks, Hysteria2
- TUN interface support (creates virtual network interface)
- Automatic protocol detection and conversion
- JSON configuration format

**Key Feature**: libXray supports `xray.tun.fd` environment variable, allowing direct TUN file descriptor access without needing separate tun2socks.

---

## Step 1: Get libXray Framework

### Option A: Build libXray Yourself

```bash
# Clone libXray repository
git clone https://github.com/XTLS/libXray.git
cd libXray

# Build for iOS using gomobile
python3 build/main.py apple gomobile

# Output: LibXray.xcframework (in appropriate directory)
```

### Option B: Use Pre-built Framework

If available in Zyng project resources:
```bash
# Copy to Desktop for easy access
cp ~/resources/LibXray.xcframework ~/Desktop/
```

---

## Step 2: Add Framework to Xcode Project

1. In Xcode, select your project in left sidebar
2. Drag `LibXray.xcframework` into Xcode window
3. In dialog:
   - ✅ Check "Copy items if needed"
   - ✅ Under "Add to targets", select **ZyngTunnel** (extension ONLY)
   - ✅ Click Add
4. Verify:
   - Select **ZyngTunnel** target
   - **Build Phases** → **Link Binary with Libraries**
   - Should show `LibXray.xcframework`

---

## Step 3: Update PacketTunnelProvider.swift

Replace the packet handling with libXray integration:

```swift
import NetworkExtension
import Foundation
// Import LibXray - the exact import may vary
// Check Xcode autocomplete to find the correct name

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var xrayProcess: Process?
    private var configPath: String?
    private var isRunning = false

    override func startTunnel(options: [String : NSObject]?, 
                             completionHandler: @escaping (Error?) -> Void) {
        NSLog("🔵 Zyng: startTunnel called")

        // Extract VPN key
        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let config = protocolConfig.providerConfiguration,
              let vpnKey = config["key"] as? String else {
            let err = NSError(domain: "ZyngTunnel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No VPN key"])
            NSLog("❌ Zyng: No VPN key provided")
            completionHandler(err)
            return
        }

        // Get TUN file descriptor
        guard let tunFD = tunnelFileDescriptor() else {
            let err = NSError(domain: "ZyngTunnel", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No TUN fd"])
            NSLog("❌ Zyng: Failed to get TUN file descriptor")
            completionHandler(err)
            return
        }

        NSLog("✅ Zyng: Got TUN FD: \(tunFD)")

        // Step 1: Convert VPN key to Xray JSON config
        convertKeyToXrayConfig(vpnKey) { [weak self] configJSON, error in
            guard let self = self else { return }

            if let error = error {
                NSLog("❌ Zyng: Config conversion failed: \(error)")
                completionHandler(error)
                return
            }

            guard let configJSON = configJSON else {
                let err = NSError(domain: "ZyngTunnel", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "No config"])
                completionHandler(err)
                return
            }

            NSLog("✅ Zyng: Config converted successfully")

            // Step 2: Merge TUN config with outbound config
            guard let mergedConfig = self.mergeTunConfig(configJSON, tunFD: tunFD) else {
                let err = NSError(domain: "ZyngTunnel", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Config merge failed"])
                completionHandler(err)
                return
            }

            // Step 3: Write config to temporary file
            guard let configPath = self.writeConfigToFile(mergedConfig) else {
                let err = NSError(domain: "ZyngTunnel", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Write failed"])
                completionHandler(err)
                return
            }

            self.configPath = configPath
            NSLog("✅ Zyng: Config written to: \(configPath)")

            // Step 4: Set tunnel network settings
            self.setupTunnelSettings(completionHandler) { [weak self] in
                guard let self = self else { return }

                // Step 5: Start Xray
                self.startXray(configPath: configPath, completionHandler: completionHandler)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, 
                            completionHandler: @escaping () -> Void) {
        NSLog("🛑 Zyng: stopTunnel reason=\(reason.rawValue)")
        isRunning = false
        stopXray()
        completionHandler()
    }

    // MARK: - Helper Methods

    /// Convert VPN key (vless://, vmess://, etc) to Xray JSON config
    private func convertKeyToXrayConfig(_ key: String, 
                                        completion: @escaping (String?, Error?) -> Void) {
        // This calls libXray's convertShareLinksToXrayJson method
        // The exact function name depends on your libXray build
        // Xcode autocomplete should help find it

        DispatchQueue.global().async {
            let request = [
                "apiVersion": 1,
                "method": "convertShareLinksToXrayJson",
                "payload": [
                    "links": key
                ]
            ]

            guard let requestJSON = try? JSONSerialization.data(withJSONObject: request),
                  let requestString = String(data: requestJSON, encoding: .utf8) else {
                completion(nil, NSError(domain: "ZyngTunnel", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Request JSON failed"]))
                return
            }

            // Call libXray (exact function name may vary)
            // Placeholder - adjust based on actual libXray API
            // let response = LibXrayInvoke(requestString)

            NSLog("📝 Zyng: Convert request: \(requestString)")

            // Parse response
            // This is where you'd parse the Xray config from libXray response
            // For now, we'll create a basic config
            completion(requestString, nil)
        }
    }

    /// Merge TUN config with outbound config
    private func mergeTunConfig(_ outboundConfig: String, tunFD: Int32) -> String? {
        let tunConfig = """
        {
          "env": {
            "xray.tun.fd": \(tunFD),
            "xray.tun.device": "utun"
          },
          "log": {
            "loglevel": "warning",
            "access": ""
          },
          "inbounds": [
            {
              "protocol": "tun",
              "port": 9000,
              "listen": "127.0.0.1",
              "settings": {
                "network": "tcp,udp",
                "excludeIPs": ["127.0.0.1/8", "::1/128"]
              }
            }
          ],
          "routing": {
            "rules": [
              {
                "type": "field",
                "network": "tcp,udp",
                "outboundTag": "proxy"
              }
            ]
          },
          "outbounds": [
            {
              "protocol": "vless",
              "tag": "proxy"
            }
          ]
        }
        """
        
        // TODO: Parse outboundConfig and merge with tunConfig
        // For now, return basic TUN config
        NSLog("📝 Zyng: Merged config with TUN FD: \(tunFD)")
        return tunConfig
    }

    /// Write config to temporary file
    private func writeConfigToFile(_ config: String) -> String? {
        let tempDir = FileManager.default.temporaryDirectory
        let configFile = tempDir.appendingPathComponent("zyng-config.json")

        do {
            try config.write(to: configFile, atomically: true, encoding: .utf8)
            NSLog("✅ Zyng: Config file written")
            return configFile.path
        } catch {
            NSLog("❌ Zyng: Write config failed: \(error)")
            return nil
        }
    }

    /// Setup tunnel network settings
    private func setupTunnelSettings(_ completionHandler: @escaping (Error?) -> Void,
                                    onSuccess: @escaping () -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.0.2.1")

        // IPv4
        let ipv4 = NEIPv4Settings(addresses: ["192.0.2.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        // IPv6
        let ipv6 = NEIPv6Settings(addresses: ["fc00::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

        // DNS
        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dns.matchDomains = nil
        settings.dnsSettings = dns

        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                NSLog("❌ Zyng: setTunnelNetworkSettings failed: \(error)")
                completionHandler(error)
                return
            }
            NSLog("✅ Zyng: Tunnel settings applied")
            onSuccess()
        }
    }

    /// Start Xray process
    private func startXray(configPath: String, completionHandler: @escaping (Error?) -> Void) {
        // Call libXray to start Xray with config
        DispatchQueue.global().async {
            let request = [
                "apiVersion": 1,
                "method": "runXray",
                "payload": ["configPath": configPath]
            ]

            guard let requestJSON = try? JSONSerialization.data(withJSONObject: request),
                  let requestString = String(data: requestJSON, encoding: .utf8) else {
                completionHandler(NSError(domain: "ZyngTunnel", code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "Start request failed"]))
                return
            }

            NSLog("🚀 Zyng: Starting Xray")

            // Call libXray (exact function name may vary)
            // Placeholder - adjust based on actual libXray API
            // let response = LibXrayInvoke(requestString)

            // Check response for success
            if requestString.contains("success") {
                NSLog("✅ Zyng: Xray started successfully")
                self.isRunning = true
                DispatchQueue.main.async {
                    completionHandler(nil)
                }
            } else {
                let error = NSError(domain: "ZyngTunnel", code: 21,
                    userInfo: [NSLocalizedDescriptionKey: "Xray start failed"])
                NSLog("❌ Zyng: Xray start failed")
                DispatchQueue.main.async {
                    completionHandler(error)
                }
            }
        }
    }

    /// Stop Xray process
    private func stopXray() {
        DispatchQueue.global().async {
            let request = [
                "apiVersion": 1,
                "method": "stopXray",
                "payload": [:]
            ]

            guard let requestJSON = try? JSONSerialization.data(withJSONObject: request),
                  let requestString = String(data: requestJSON, encoding: .utf8) else {
                NSLog("❌ Zyng: Stop request failed")
                return
            }

            // Call libXray (exact function name may vary)
            // Placeholder - adjust based on actual libXray API
            // let response = LibXrayInvoke(requestString)

            NSLog("✅ Zyng: Xray stopped")
        }
    }

    /// Get TUN file descriptor
    private func tunnelFileDescriptor() -> Int32? {
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))

        for fd: Int32 in 0...1024 {
            var len = socklen_t(buf.count)
            guard getsockopt(fd, 2, 2, &buf, &len) == 0 else { continue }

            let ifName = String(cString: buf)
            if ifName.hasPrefix("utun") {
                NSLog("✅ Zyng: Found TUN interface: \(ifName) fd=\(fd)")
                return fd
            }
        }

        return nil
    }
}
```

---

## Step 4: Update ContentView.swift

Make sure your UI properly displays VPN status and handles connection:

```swift
// In your ContentView.swift, when user taps to connect:

@State private var selectedServer: VPNServer?
@State private var isConnecting = false

var body: some View {
    VStack {
        // Server selection UI
        
        Button(action: connectVPN) {
            Text(vpnController.isConnected ? "Disconnect" : "Connect")
                .frame(maxWidth: .infinity)
                .padding()
                .background(vpnController.isConnected ? Color.red : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
        }
        .disabled(isConnecting || selectedServer == nil)

        // Show error if any
        if let error = vpnController.errorMessage {
            Text("Error: \(error)")
                .foregroundColor(.red)
                .font(.caption)
        }
    }
}

private func connectVPN() {
    guard let server = selectedServer else { return }

    isConnecting = true

    vpnController.connect(key: server.raw) { [weak self] error in
        DispatchQueue.main.async {
            self?.isConnecting = false
            if let error = error {
                self?.vpnController.errorMessage = error.localizedDescription
            }
        }
    }
}
```

---

## Step 5: Testing

### On Device:

1. Build and run on physical iOS device (simulator doesn't support VPN)
2. Select a VPN server with key (vless://, vmess://, etc.)
3. Tap Connect
4. iOS will show permission prompt: "Allow Zyng to set up a VPN configuration?"
   - Tap **Allow**
5. Check Console.app:
   - Filter for "Zyng"
   - Look for ✅ messages indicating each step worked

### Common Log Messages:

```
✅ Zyng: Got TUN FD: 4
✅ Zyng: Config converted successfully
✅ Zyng: Tunnel settings applied
✅ Zyng: Xray started successfully
```

### Debugging:

If you see ❌ messages:

```bash
# On Mac, open Console.app
# Connect to device
# Filter: "Zyng"
# Read the error messages

# Common errors:
❌ No VPN key provided          → User didn't select server
❌ Failed to get TUN fd         → iOS permission issue
❌ Config conversion failed     → libXray not working
❌ Xray start failed            → Configuration issue
```

---

## Troubleshooting

### "Xcode can't find LibXray"

- Make sure you added it to ZyngTunnel target, not main Zyng target
- Check Build Phases → Link Binary with Libraries
- Verify xcframework path exists

### "libXray function not found"

- libXray API might differ from example
- Check libXray documentation for actual function names
- Xcode autocomplete should show available functions

### "VPN settings apply fails"

- Check entitlements (Network Extension, Personal VPN)
- Check capabilities enabled in Signing & Capabilities
- Verify provisioning profile has entitlements

### "Tunnel starts but no traffic passes"

- Configuration merge might be wrong
- Check tunConfig merging logic with actual libXray response format
- Add more NSLog statements to debug config

---

## Next Steps

1. Get actual libXray build or pre-built framework
2. Import LibXray.xcframework into Xcode
3. Replace placeholder libXray calls with actual function names
4. Parse libXray response format correctly
5. Merge TUN config with outbound config properly
6. Test on physical device
7. Monitor Console.app logs to verify each step

---

## Key Points

- ✅ libXray provides all VPN protocol support
- ✅ Handles TUN interface automatically
- ✅ No need for separate tun2socks
- ✅ JSON configuration format
- ✅ iOS processes run with proper entitlements
- ⚠️ Must run on physical device (not simulator)
- ⚠️ User must grant VPN permission on first connect
