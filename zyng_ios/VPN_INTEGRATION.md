# Zyng iOS — реальный VPN через Xray (libXray, MPL-2.0)

Движок собран: `LibXray.xcframework` (из github.com/XTLS/libXray, `python3 build/main.py apple gomobile`).
libXray сам поддерживает TUN (`xray.tun.fd` в root `env` конфига) и сам конвертит ключи
(`convertShareLinksToXrayJson`). Отдельный tun2socks НЕ нужен.

## 1. Добавить движок в проект Zyng
- Перетащи `~/Desktop/libXray/LibXray.xcframework` в Xcode, в проект Zyng (в список файлов слева).
- В диалоге: галка **Copy items if needed**, и в **Add to targets** отметь **ZyngTunnel** (расширение).
- Проверь: target **ZyngTunnel → General → Frameworks and Libraries** → там `LibXray.xcframework` (Embed & Sign).

## 2. Capabilities (у главного app и у ZyngTunnel — ОБА)
Для каждого таргета: Signing & Capabilities → «+ Capability»:
- **Network Extensions** → отметь **Packet Tunnel**
- **App Groups** → добавь одинаковую группу: `group.online.zyng.Zyng`

## 3. PacketTunnelProvider.swift (расширение ZyngTunnel)
```swift
import NetworkExtension
import LibXray

class PacketTunnelProvider: NEPacketTunnelProvider {

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // Ключ передаётся из приложения через providerConfiguration
        let proto = self.protocolConfiguration as? NETunnelProviderProtocol
        let key = (proto?.providerConfiguration?["key"] as? String) ?? ""

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error { completionHandler(error); return }

            guard let fd = self.tunnelFileDescriptor() else {
                completionHandler(NSError(domain: "Zyng", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "no tun fd"])); return
            }

            // 1) ключ vless:// -> Xray outbound JSON (libXray сам конвертит)
            let convReq = "{\"apiVersion\":1,\"method\":\"convertShareLinksToXrayJson\",\"payload\":{\"links\":\"\(key)\"}}"
            let convResp = LibXrayInvoke(convReq)   // если имя функции другое — Xcode подскажет
            NSLog("Zyng convert: \(convResp)")

            // 2) собрать полный конфиг с TUN (fd в env) + outbound из конверта
            // ВНИМАНИЕ: точную схему tun-inbound/outbound подставим по ответу convResp.
            let configPath = self.writeConfig(fd: fd, convertResponse: convResp)

            // 3) запустить Xray
            let runReq = "{\"apiVersion\":1,\"method\":\"runXray\",\"payload\":{\"configPath\":\"\(configPath)\"}}"
            let runResp = LibXrayInvoke(runReq)
            NSLog("Zyng runXray: \(runResp)")

            if runResp.contains("\"success\":true") {
                completionHandler(nil)
            } else {
                completionHandler(NSError(domain: "Zyng", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: runResp]))
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        _ = LibXrayInvoke("{\"apiVersion\":1,\"method\":\"stopXray\",\"payload\":{}}")
        completionHandler()
    }

    // приём tun fd (стандартный приём для NEPacketTunnelProvider)
    private func tunnelFileDescriptor() -> Int32? {
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd: Int32 in 0...1024 {
            var len = socklen_t(buf.count)
            if getsockopt(fd, 2, 2, &buf, &len) == 0, String(cString: buf).hasPrefix("utun") {
                return fd
            }
        }
        return nil
    }

    // пишет конфиг во временный файл, возвращает путь.
    private func writeConfig(fd: Int32, convertResponse: String) -> String {
        // Извлекаем outbound из ответа convertShareLinksToXrayJson (JSON: {success,data,error}).
        // data содержит готовый Xray json c outbounds. Мы добавляем env с fd и tun inbound.
        // ⚠️ Точную склейку до定им по реальному convertResponse (см. лог NSLog выше).
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("zyng-config.json")
        // Пока плейсхолдер — заменим на разбор convertResponse:
        let cfg = """
        {
          "env": { "xray.tun.fd": \(fd) },
          "log": { "loglevel": "warning" },
          "inbounds": [{ "protocol": "tun", "settings": {} }],
          "outbounds": []
        }
        """
        try? cfg.write(to: base, atomically: true, encoding: .utf8)
        return base.path
    }
}
```

## 4. Приложение — старт/стоп VPN (в главном app)
```swift
import NetworkExtension

final class VPNController {
    static let shared = VPNController()
    private var manager: NETunnelProviderManager?

    func connect(key: String, completion: @escaping (String?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            let m = managers?.first ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = "online.zyng.Zyng.ZyngTunnel" // = bundle расширения
            proto.serverAddress = "Zyng"
            proto.providerConfiguration = ["key": key]
            m.protocolConfiguration = proto
            m.localizedDescription = "Zyng VPN"
            m.isEnabled = true
            m.saveToPreferences { err in
                if let err = err { completion(err.localizedDescription); return }
                m.loadFromPreferences { _ in
                    do {
                        try m.connection.startVPNTunnel()
                        self.manager = m
                        completion(nil)
                    } catch { completion(error.localizedDescription) }
                }
            }
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }
}
```
В `ContentView` при нажатии орба: `VPNController.shared.connect(key: selected!.raw) { err in ... }`.
Первый запуск iOS покажет системный запрос «Разрешить VPN-конфигурацию» — нажать Allow.

## 5. Что почти наверняка потребует правки (честно)
- Имя Swift-функции: `LibXrayInvoke(...)` — Xcode подскажет автодополнением реальное имя из модуля `LibXray`.
- Имя поля в `convertShareLinksToXrayJson` payload (`links` / `shareLinks` / `text`) — смотри лог `NSLog("Zyng convert: ...")`, там будет ответ с ошибкой если поле не то.
- Точная схема `tun` inbound для этой сборки Xray — подставим по реальному ответу конвертации и по докам libXray. Это главный пункт отладки.
- `providerBundleIdentifier` должен точно совпадать с Bundle ID таргета ZyngTunnel.

Порядок отладки: собрать → запустить на телефоне → смотреть Console.app (фильтр «Zyng») → присылать строки NSLog.
