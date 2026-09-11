import NetworkExtension
import Foundation

/// Packet tunnel расширение Zyng.
///
/// ВАЖНО, честно: транспорта за этим туннелем пока нет. Пакеты, прочитанные из
/// `packetFlow`, никуда не отправляются — движок (libXray) ещё не подключён.
/// Поэтому `routesAllTraffic` по умолчанию `false`: туннель поднимается и живёт,
/// но не забирает на себя весь трафик устройства. Так можно проверить, что
/// расширение вообще грузится и не убивается системой, не теряя интернет.
///
/// После интеграции libXray — переключить `routesAllTraffic` в `true`.
final class PacketTunnelProvider: NEPacketTunnelProvider {

    /// Включать только когда пакеты реально куда-то пересылаются. Иначе маршрут
    /// по умолчанию просто «съедает» все соединения на устройстве.
    private static let routesAllTraffic = false

    /// Читается из цикла чтения пакетов и пишется из stopTunnel — это разные потоки,
    /// поэтому доступ под замком.
    private let lock = NSLock()
    private var _isRunning = false

    private var isRunning: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isRunning }
        set { lock.lock(); _isRunning = newValue; lock.unlock() }
    }

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        NSLog("🔵 Zyng: startTunnel")

        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.providerConfiguration,
              let key = config["key"] as? String,
              !key.isEmpty else {
            NSLog("❌ Zyng: в конфигурации нет ключа")
            completionHandler(NSError(
                domain: "ZyngTunnel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "VPN key missing from configuration"]
            ))
            return
        }

        NSLog("✅ Zyng: ключ получен (\(key.count) симв.)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.0.2.1")

        // 198.18.0.0/15 — диапазон для бенчмарков, его использует большинство
        // VPN-клиентов: он гарантированно не пересечётся с сетью пользователя.
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = Self.routesAllTraffic
            ? [NEIPv4Route.default()]
            : [NEIPv4Route(destinationAddress: "198.18.0.0", subnetMask: "255.255.0.0")]
        settings.ipv4Settings = ipv4

        // IPv6 намеренно не настраиваем: маршрут по умолчанию без транспорта
        // просто заблокировал бы весь IPv6-трафик.

        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        // Документированный способ перехватить все домены — [""].
        // Прежнее `nil` оставляло резолвинг системе, и DNS в туннель не попадал вовсе.
        dns.matchDomains = Self.routesAllTraffic ? [""] : []
        settings.dnsSettings = dns

        // 1500 — это MTU физического интерфейса. Для туннеля нужен запас под
        // заголовки инкапсуляции, иначе пакеты фрагментируются.
        settings.mtu = 1400

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(NSError(
                    domain: "ZyngTunnel", code: 99,
                    userInfo: [NSLocalizedDescriptionKey: "Provider deallocated"]
                ))
                return
            }

            if let error {
                NSLog("❌ Zyng: setTunnelNetworkSettings: \(error.localizedDescription)")
                completionHandler(error)
                return
            }

            NSLog("✅ Zyng: сетевые настройки туннеля применены")
            self.isRunning = true
            completionHandler(nil)
            self.readPackets()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        NSLog("🛑 Zyng: stopTunnel, причина \(reason.rawValue)")
        isRunning = false
        completionHandler()
    }

    /// Цикл чтения пакетов.
    ///
    /// Здесь раньше был `NSLog` на каждую пачку пакетов. С маршрутом по умолчанию
    /// это давало непрерывный поток записей в лог: NSLog синхронный, а у packet
    /// tunnel расширения жёсткий лимит памяти и CPU — система убивала процесс
    /// (тот самый SIGKILL). Логировать здесь нельзя.
    private func readPackets() {
        guard isRunning else { return }

        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.isRunning else { return }

            // TODO: передать `packets` в транспорт (libXray) и записать ответные
            // пакеты обратно через packetFlow.writePackets(_:withProtocols:).
            // Пока пакеты отбрасываются — см. комментарий к routesAllTraffic.

            self.readPackets()
        }
    }
}
