import Foundation

/// Разрешение имён в обход системного резолвера.
///
/// Зачем это понадобилось. Системный резолвер спрашивает тот DNS, который
/// выдал провайдер или оператор связи. Оператор вправе ответить что угодно —
/// и отвечает: имена серверов подписки разрешались в адреса, принадлежащие
/// самому оператору. В журнале это выглядело так:
///
///     dns: lookup succeed for node.kerimlicorp.com: 76.13.79.233
///
/// 76.13.79.233 — адрес Verizon, оператора телефона. Сервер с флагом Латвии
/// в американской сети оператора не стоит. Это подмена: оператор возвращает
/// свой адрес вместо настоящего, соединение уходит в никуда и молча висит до
/// истечения времени. Снаружи — «сервер не отвечает», хотя сервер жив, а в
/// других клиентах тот же ключ работает: они спрашивают не оператора.
///
/// Поэтому спрашиваем сами, по HTTPS. Адрес резолвера числовой, так что
/// разрешать его самого не нужно, а ответ приходит внутри TLS — подменить
/// его по дороге нельзя.
enum SecureDNS {

    /// Резолверы по порядку. Оба принимают запрос прямо по IP-адресу, и у
    /// обоих этот адрес вписан в сертификат — проверка подлинности проходит.
    private static let resolvers = [
        "https://1.1.1.1/dns-query",
        "https://8.8.8.8/resolve"
    ]

    /// Разобранное держим при себе: за одно подключение одно и то же имя
    /// спрашивают и проверка задержки, и маршруты, и второе ядро.
    private static let cacheLifetime: TimeInterval = 300

    /// Кэш в объекте, а не в статической переменной: изменяемое статическое
    /// свойство в общем для двух процессов файле компилятор не пропускает.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: (addresses: [String], at: Date)] = [:]

        func value(_ key: String) -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = storage[key],
                  Date().timeIntervalSince(entry.at) < cacheLifetime else { return nil }
            return entry.addresses
        }

        func store(_ addresses: [String], for key: String) {
            lock.lock()
            storage[key] = (addresses, Date())
            lock.unlock()
        }
    }

    private static let cache = Cache()

    /// Уже числовой адрес разрешать не нужно и нельзя: DoH на него ответит
    /// отказом, и мы потеряем рабочий адрес на ровном месте.
    static func isNumeric(_ host: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, host, &v6) == 1
    }

    /// Кто ответил на последний запрос — «защищённый DNS» или «система».
    /// Нужно только для дневника: по нему видно, сработал ли обход подмены.
    private static let sourceCache = Cache()

    static func lastSource(for host: String) -> String {
        sourceCache.value(host)?.first ?? "?"
    }

    /// Адреса имени. Пустой список — не удалось.
    static func resolve(_ host: String) async -> [String] {
        if isNumeric(host) { return [host] }

        if let cached = cache.value(host) { return cached }

        for resolver in resolvers {
            let addresses = await query(host, via: resolver)
            guard !addresses.isEmpty else { continue }
            cache.store(addresses, for: host)
            sourceCache.store(["защищённый DNS"], for: host)
            return addresses
        }

        // Последняя попытка — системный резолвер.
        //
        // Он и есть источник неприятностей, но остаться совсем без адреса
        // хуже: бывают сети, где наружу пускают только через свой прокси, и
        // тогда DoH не пройдёт, а обычный запрос — да.
        let system = systemResolve(host)
        if !system.isEmpty {
            cache.store(system, for: host)
            sourceCache.store(["системный DNS — возможна подмена"], for: host)
        }
        return system
    }

    /// Синхронный вариант — для расширения.
    ///
    /// Расширение строит конфиг и маршруты в обычном потоке, до того как
    /// туннель поднят, и ждать здесь можно: работы всё равно нет, пока имя не
    /// разрешено. На главном потоке приложения этот вызов недопустим — там
    /// есть асинхронный.
    static func resolveSync(_ host: String, timeout: TimeInterval = 5) -> [String] {
        if isNumeric(host) { return [host] }

        let semaphore = DispatchSemaphore(value: 0)
        var result: [String] = []

        Task {
            result = await resolve(host)
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    /// Обычный системный резолвер — только как последняя надежда.
    private static func systemResolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let first = head else { return [] }
        defer { freeaddrinfo(head) }

        var result: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let addr = ptr.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, ptr.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: buffer).components(separatedBy: "%").first ?? ""
            if !text.isEmpty, !result.contains(text) { result.append(text) }
        }
        return result
    }

    // MARK: - Запрос

    private static func query(_ host: String, via resolver: String) async -> [String] {
        var addresses: [String] = []
        // A и AAAA спрашиваем отдельно: JSON-ответ содержит только один тип.
        for type in ["A", "AAAA"] {
            guard var components = URLComponents(string: resolver) else { continue }
            components.queryItems = [
                URLQueryItem(name: "name", value: host),
                URLQueryItem(name: "type", value: type)
            ]
            guard let url = components.url else { continue }

            var request = URLRequest(url: url)
            // Без этого заголовка резолверы отвечают двоичным форматом DNS.
            request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 4
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 4
            config.timeoutIntervalForResource = 6
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }

            guard let (data, _) = try? await session.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = json["Answer"] as? [[String: Any]] else {
                continue
            }

            for answer in answers {
                // Тип 1 — A, тип 28 — AAAA. Остальное (например, CNAME)
                // пропускаем: соединяться по имени из CNAME смысла нет.
                guard let recordType = answer["type"] as? Int, recordType == 1 || recordType == 28,
                      let value = answer["data"] as? String, isNumeric(value) else { continue }
                if !addresses.contains(value) { addresses.append(value) }
            }
        }
        return addresses
    }
}
