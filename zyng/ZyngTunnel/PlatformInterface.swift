import Foundation
import Libcore
import NetworkExtension
import Network

/// Мост между ядром sing-box и iOS.
///
/// Ядро само разбирает пакеты, держит TCP/IP-стек и маршрутизацию. От платформы
/// ему нужно немного: открыть TUN-интерфейс, сообщать о смене сети и отдавать
/// список интерфейсов. Всё это здесь.
final class PlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {

    private weak var provider: NEPacketTunnelProvider?

    /// IPv4-адреса самого VPN-сервера — их нужно вывести из туннеля.
    ///
    /// Зачем. sing-box умеет привязывать свои исходящие сокеты к настоящему
    /// сетевому интерфейсу (auto_detect_interface). Xray так не умеет вообще:
    /// он просто открывает соединение, а маршрут по умолчанию после поднятия
    /// туннеля — сам туннель. Получается круг, который в журнале выглядит так:
    ///
    ///     76.13.79.233:1234 ... interface: utun5 ... already failing
    ///
    /// Пока Xray вёл только xhttp, это всплывало редко. Когда он стал вести
    /// все ключи (vless/vmess/trojan/tcp/http/xhttp — как в Happ и OneXray),
    /// круг замкнулся на каждом.
    ///
    /// Решение то же, что у всех клиентов: адрес сервера исключается из
    /// маршрутов туннеля. Тогда соединение с ним идёт мимо туннеля — кто бы
    /// его ни открыл, ядро или Xray.
    private let bypassIPv4: [String]

    /// IPv6-адреса сервера, по той же причине.
    private let bypassIPv6: [String]

    /// Монитор сети живёт, пока ядро на него подписано.
    private var monitor: NWPathMonitor?

    /// Последний интерфейс, о котором мы сообщили ядру.
    private var lastInterface: String?
    private let monitorQueue = DispatchQueue(label: "online.zyng.tunnel.path")

    /// Ядро открывает туннель своим потоком уже после того, как запуск сервиса
    /// вернул управление. Пока это не произошло, сетевые настройки не применены
    /// и система держит статус «подключение» — поэтому запуск ждёт этот сигнал.
    private let tunnelOpened = DispatchSemaphore(value: 0)

    /// Ждёт, пока ядро откроет туннель. false — не дождались.
    func waitUntilTunnelOpened(timeout: TimeInterval) -> Bool {
        tunnelOpened.wait(timeout: .now() + timeout) == .success
    }

    init(provider: NEPacketTunnelProvider, bypassIPv4: [String] = [], bypassIPv6: [String] = []) {
        self.provider = provider
        self.bypassIPv4 = bypassIPv4
        self.bypassIPv6 = bypassIPv6
        super.init()
    }

    // MARK: - Открытие туннеля

    /// Ядро посчитало адреса, маршруты, MTU и DNS из конфига — перекладываем их
    /// в NEPacketTunnelNetworkSettings и возвращаем файловый дескриптор.
    ///
    /// Метод синхронный: ядро вызывает его из своего потока и ждёт результата.
    /// А setTunnelNetworkSettings асинхронный, поэтому ждём его семафором.
    func openTun(_ options: LibboxTunOptionsProtocol?,
                 ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options else {
            throw NSError(domain: "ZyngTunnel", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Ядро не передало параметры туннеля"])
        }
        guard let provider else {
            throw NSError(domain: "ZyngTunnel", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Расширение уже выгружено"])
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        let autoRoute = options.getAutoRoute()

        // --- IPv4 ---

        let v4addresses = prefixes(options.getInet4Address())
        if !v4addresses.isEmpty {
            let ipv4 = NEIPv4Settings(
                addresses: v4addresses.map(\.address),
                subnetMasks: v4addresses.map(\.mask)
            )

            if autoRoute {
                let explicit = prefixes(options.getInet4RouteAddress())
                ipv4.includedRoutes = explicit.isEmpty
                    ? [NEIPv4Route.default()]
                    : explicit.map { NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask) }

                var excluded = prefixes(options.getInet4RouteExcludeAddress())
                    .map { NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask) }

                // Адрес самого сервера — мимо туннеля. Иначе соединение с ним
                // уходит в туннель, который без этого соединения не работает.
                for ip in bypassIPv4 {
                    excluded.append(NEIPv4Route(destinationAddress: ip,
                                                subnetMask: "255.255.255.255"))
                }

                ipv4.excludedRoutes = excluded
            }

            settings.ipv4Settings = ipv4
        }

        // --- IPv6 ---

        let v6addresses = prefixes(options.getInet6Address())
        if !v6addresses.isEmpty {
            let ipv6 = NEIPv6Settings(
                addresses: v6addresses.map(\.address),
                networkPrefixLengths: v6addresses.map { NSNumber(value: $0.prefix) }
            )

            if autoRoute {
                let explicit = prefixes(options.getInet6RouteAddress())
                ipv6.includedRoutes = explicit.isEmpty
                    ? [NEIPv6Route.default()]
                    : explicit.map { NEIPv6Route(destinationAddress: $0.address,
                                                 networkPrefixLength: NSNumber(value: $0.prefix)) }

                var excluded = prefixes(options.getInet6RouteExcludeAddress())
                    .map { NEIPv6Route(destinationAddress: $0.address,
                                       networkPrefixLength: NSNumber(value: $0.prefix)) }

                for ip in bypassIPv6 {
                    excluded.append(NEIPv6Route(destinationAddress: ip,
                                                networkPrefixLength: 128))
                }

                ipv6.excludedRoutes = excluded
            }

            settings.ipv6Settings = ipv6
        }

        // --- DNS ---

        if let box = try? options.getDNSServerAddress(), !box.value.isEmpty {
            let dns = NEDNSSettings(servers: [box.value])
            // [""] — документированный способ перехватить резолвинг всех доменов.
            dns.matchDomains = [""]
            settings.dnsSettings = dns
        }

        // --- HTTP-прокси, если ядро его подняло ---

        if options.isHTTPProxyEnabled() {
            let proxy = NEProxySettings()
            let server = NEProxyServer(address: options.getHTTPProxyServer(),
                                       port: Int(options.getHTTPProxyServerPort()))
            proxy.httpEnabled = true
            proxy.httpServer = server
            proxy.httpsEnabled = true
            proxy.httpsServer = server
            proxy.exceptionList = strings(options.getHTTPProxyBypassDomain())
            proxy.matchDomains = strings(options.getHTTPProxyMatchDomain())
            settings.proxySettings = proxy
        }

        // --- Применяем и ждём ---

        var applyError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        provider.setTunnelNetworkSettings(settings) { error in
            applyError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let applyError {
            throw applyError
        }

        let fd = LibboxGetTunnelFileDescriptor()
        guard fd > 0 else {
            throw NSError(domain: "ZyngTunnel", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "Не удалось получить дескриптор туннеля"])
        }

        ret0_?.pointee = fd

        TunnelDiagnostics.note("сетевые настройки применены, дескриптор \(fd)")
        NSLog("✅ Zyng: туннель открыт, настройки применены")
        tunnelOpened.signal()
    }

    // MARK: - Отслеживание сети
    //
    // Нужно, чтобы туннель переживал переключение Wi-Fi ↔ сотовая связь,
    // а не рвался при выходе из дома.

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }

        let monitor = NWPathMonitor()
        self.monitor = monitor

        let ready = DispatchSemaphore(value: 0)
        var reported = false

        monitor.pathUpdateHandler = { [weak self] path in
            let name = Self.defaultInterface(of: path)
            let index = name.isEmpty ? 0 : Int32(if_nametoindex(name))

            // Сообщаем только о смене — иначе дневник забьётся повторами.
            if name != self?.lastInterface {
                self?.lastInterface = name
                TunnelDiagnostics.note("сеть идёт через \(name.isEmpty ? "—" : name)")
            }

            listener.updateDefaultInterface(
                name,
                interfaceIndex: index,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )

            // Первый вызов разблокирует запуск: ядру нужен интерфейс, чтобы
            // вообще начать соединение.
            if !reported {
                reported = true
                ready.signal()
            }
        }

        monitor.start(queue: monitorQueue)
        _ = ready.wait(timeout: .now() + 3)
    }

    /// Какой интерфейс сейчас реально несёт трафик.
    ///
    /// ЗДЕСЬ БЫЛ ГЛАВНЫЙ ДЕФЕКТ. Стояло `path.availableInterfaces.first` —
    /// то есть «первый из списка». Список этот не отсортирован по тому, каким
    /// интерфейсом система пользуется: он просто перечисляет доступные, и en0
    /// (Wi-Fi) стоит в нём первым практически всегда — даже когда телефон
    /// сидит на сотовой связи, а к Wi-Fi лишь подключён без интернета или не
    /// подключён вовсе.
    ///
    /// Ядро получало от нас «работай через en0», честно привязывало туда сокет
    /// и упиралось в тишину. В журнале это и было видно дословно:
    ///
    ///     dial en0 (5): dial tcp 76.13.79.233:1234: i/o timeout
    ///
    /// — телефон в этот момент был на 5G. Сервер был жив и ни при чём.
    ///
    /// Теперь берём первый интерфейс, ТИП которого путь действительно
    /// использует, и пропускаем туннельные: utun — это мы сами, привязка к
    /// нему замкнула бы трафик на себя.
    private static func defaultInterface(of path: Network.NWPath) -> String {
        let candidates = path.availableInterfaces.filter { iface in
            !iface.name.hasPrefix("utun")
                && !iface.name.hasPrefix("ipsec")
                && !iface.name.hasPrefix("lo")
        }

        if let used = candidates.first(where: { path.usesInterfaceType($0.type) }) {
            return used.name
        }

        // Путь ничего не подтвердил — отдаём первый непустой, чтобы ядро не
        // осталось совсем без интерфейса.
        return candidates.first?.name ?? ""
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        monitor?.cancel()
        monitor = nil
    }

    /// Список сетевых интерфейсов устройства — ядро использует его для выбора
    /// исходящего соединения.
    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        var result: [LibboxNetworkInterface] = []

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return NetworkInterfaceIterator([])
        }
        defer { freeifaddrs(head) }

        // У одного интерфейса несколько адресов — собираем по имени.
        var byName: [String: [String]] = [:]
        var flagsByName: [String: Int32] = [:]

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let name = String(cString: ifa.ifa_name)
            flagsByName[name] = Int32(ifa.ifa_flags)

            guard let addr = ifa.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(addr.pointee.sa_len)
            guard getnameinfo(addr, length, &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }

            var text = String(cString: host)

            // getnameinfo дописывает к link-local адресам зону: fe80::1%utun5.
            // Ядро такой адрес не разбирает.
            if let percent = text.firstIndex(of: "%") {
                text = String(text[text.startIndex..<percent])
            }

            // Ядро ждёт именно префикс — «адрес/длина». Голый адрес роняет его
            // в netip.ParsePrefix с «no '/'».
            let prefix = Self.prefixLength(of: ifa.ifa_netmask, family: family)
            byName[name, default: []].append("\(text)/\(prefix)")
        }

        for (name, addresses) in byName {
            let iface = LibboxNetworkInterface()
            iface.name = name
            iface.index = Int32(if_nametoindex(name))
            iface.flags = flagsByName[name] ?? 0
            iface.addresses = StringIterator(addresses)
            iface.type = Self.interfaceType(name)
            result.append(iface)
        }

        return NetworkInterfaceIterator(result)
    }

    /// Длина префикса = количество единичных битов в сетевой маске.
    private static func prefixLength(of mask: UnsafeMutablePointer<sockaddr>?,
                                     family: UInt8) -> Int32 {
        let full: Int32 = family == UInt8(AF_INET) ? 32 : 128
        guard let mask else { return full }

        // Смещение и длина той части структуры, где лежат байты маски.
        let offset: Int
        let count: Int
        if family == UInt8(AF_INET) {
            offset = MemoryLayout<sockaddr_in>.offset(of: \.sin_addr) ?? 4
            count = 4
        } else {
            offset = MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr) ?? 8
            count = 16
        }

        // sa_len у маски бывает урезанным — читать за его границей нельзя.
        let available = Int(mask.pointee.sa_len) - offset
        guard available > 0 else { return full }

        var bits: Int32 = 0
        let raw = UnsafeRawPointer(mask).advanced(by: offset)
        for i in 0..<min(count, available) {
            bits += Int32(raw.load(fromByteOffset: i, as: UInt8.self).nonzeroBitCount)
        }
        return bits
    }

    private static func interfaceType(_ name: String) -> Int32 {
        if name.hasPrefix("en") { return LibboxInterfaceTypeWIFI }
        if name.hasPrefix("pdp_ip") { return LibboxInterfaceTypeCellular }
        return LibboxInterfaceTypeOther
    }

    // MARK: - Остальное

    /// Привязку сокетов делает САМО ядро, не мы.
    ///
    /// Здесь стояло true, и это была тяжёлая ошибка. Значение true означает
    /// «платформа берёт привязку сокетов на себя», после чего ядро своей
    /// привязкой не занимается — полагается на нас. А наша реализация
    /// autoDetectControl не делала ничего, вообще.
    ///
    /// В итоге исходящие соединения ядра не привязывались ни к какому
    /// интерфейсу и шли по маршруту по умолчанию. А маршрут по умолчанию,
    /// после того как туннель поднят, — это сам туннель. Получался замкнутый
    /// круг: чтобы дойти до сервера, пакет отправлялся в туннель, который без
    /// этого сервера не работает. В журнале это видно прямо:
    ///
    ///     node.kerimlicorp.com:1234 ... interface: utun5 ... already failing
    ///
    /// utun5 — наш собственный туннель. Снаружи это выглядело как «Защищено,
    /// но ни одна страница не открывается», и никакой ошибки при этом нет:
    /// туннель ведь честно поднялся.
    ///
    /// С false ядро привязывает сокеты само — у него для этого есть
    /// auto_detect_interface в маршрутах, и он выбирает настоящий сетевой
    /// интерфейс, а не туннельный.
    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_ fd: Int32) throws {}

    func underNetworkExtension() -> Bool { true }

    /// includeAllNetworks меняет поведение системного роутинга и требует
    /// отдельного разрешения. Нам не нужно.
    func includeAllNetworks() -> Bool { false }

    /// procfs — это Linux/Android. На iOS его нет.
    func useProcFS() -> Bool { false }

    /// Определение процесса-владельца соединения на iOS недоступно.
    func findConnectionOwner(_ ipProtocol: Int32,
                             sourceAddress: String?,
                             sourcePort: Int32,
                             destinationAddress: String?,
                             destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw NSError(domain: "ZyngTunnel", code: 13,
                      userInfo: [NSLocalizedDescriptionKey: "Not supported on iOS"])
    }

    /// Системный DNS не перехватываем — резолвингом занимается само ядро
    /// по правилам из конфига.
    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }

    /// Читать SSID можно только с разрешением на геолокацию. Не запрашиваем.
    func readWIFIState() -> LibboxWIFIState? { nil }

    /// Корневые сертификаты берутся системные.
    func systemCertificates() -> LibboxStringIteratorProtocol? { nil }

    func clearDNSCache() {}

    func send(_ notification: LibboxNotification?) throws {}

    // MARK: - Разбор итераторов ядра

    private struct Prefix {
        let address: String
        let mask: String
        let prefix: Int32
    }

    private func prefixes(_ iterator: LibboxRoutePrefixIteratorProtocol?) -> [Prefix] {
        guard let iterator else { return [] }
        var result: [Prefix] = []
        while iterator.hasNext() {
            guard let p = iterator.next() else { break }
            result.append(Prefix(address: p.address(), mask: p.mask(), prefix: p.prefix()))
        }
        return result
    }

    private func strings(_ iterator: LibboxStringIteratorProtocol?) -> [String] {
        guard let iterator else { return [] }
        var result: [String] = []
        while iterator.hasNext() {
            result.append(iterator.next())
        }
        return result
    }
}

// MARK: - Итераторы для передачи данных обратно в ядро

/// Ядро принимает списки только через свои итераторы, поэтому оборачиваем массивы.
final class StringIterator: NSObject, LibboxStringIteratorProtocol {
    private let values: [String]
    private var index = 0

    init(_ values: [String]) {
        self.values = values
    }

    func hasNext() -> Bool { index < values.count }

    func len() -> Int32 { Int32(values.count) }

    func next() -> String {
        guard index < values.count else { return "" }
        defer { index += 1 }
        return values[index]
    }
}

final class NetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private let values: [LibboxNetworkInterface]
    private var index = 0

    init(_ values: [LibboxNetworkInterface]) {
        self.values = values
    }

    func hasNext() -> Bool { index < values.count }

    func next() -> LibboxNetworkInterface? {
        guard index < values.count else { return nil }
        defer { index += 1 }
        return values[index]
    }
}
