import Foundation

/// Превращает ссылку-ключ (vless://, vmess://, trojan://, ss:// и т.д.)
/// в готовый JSON-конфиг sing-box.
///
/// Живёт в Shared/ и компилируется в оба таргета: приложению нужно проверить,
/// что ключ вообще разбирается, расширению — построить конфиг для ядра.
enum SingBoxConfig {

    enum ParseError: LocalizedError {
        case emptyKey
        case unsupportedScheme(String)
        case unsupportedTransport(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .emptyKey:
                return tr("Ключ пустой", "The key is empty")
            case .unsupportedScheme(let s):
                return tr("Протокол «\(s)» не поддерживается", "The «\(s)» protocol is not supported")
            case .unsupportedTransport(let t):
                return tr("Транспорт «\(t)» не умеет ни одно из ядер Zyng. "
                        + "Выбери в этой же подписке сервер той же страны "
                        + "с пометкой tcp, ws, grpc, http, httpupgrade или xhttp.",
                          "Neither of Zyng's cores supports the «\(t)» transport. "
                        + "Pick a server for the same country in this subscription "
                        + "marked tcp, ws, grpc, http, httpupgrade or xhttp.")
            case .malformed(let why):
                return tr("Ключ повреждён: \(why)", "The key is malformed: \(why)")
            }
        }
    }

    // MARK: - Точка входа

    /// Полный конфиг sing-box для одного сервера.
    ///
    /// `dns` — адрес резолвера из настроек приложения. Через него пойдут
    /// запросы внутри туннеля.
    static func makeConfig(from key: String,
                           dns: String = "1.1.1.1",
                           verbose: Bool = false) throws -> String {
        // Транспорт, которого нет в этом ядре, исполняет Xray. Тогда sing-box
        // остаётся туннелем, а весь трафик отдаёт в локальный SOCKS, который
        // Xray слушает внутри того же процесса расширения.
        let outbound: [String: Any]
        if needsXray(key) {
            outbound = [
                "type": "socks",
                "tag": "proxy",
                "version": "5",
                "server": "127.0.0.1",
                "server_port": XrayBridge.socksPort,
                // Имена разрешает sing-box, а Xray получает готовый адрес.
                //
                // Иначе выходит замкнутый круг: Xray просит у системы разрешить
                // имя, системный резолвер направлен в наш же туннель, запрос
                // возвращается к sing-box, тот отправляет его в этот самый
                // SOCKS — и снова к Xray, который всё ещё ждёт первого ответа.
                // Снаружи это выглядит как «подключено, но ничего не грузится».
                "domain_strategy": "ipv4_only"
            ]
        } else {
            outbound = try makeOutbound(from: key)
        }

        let config: [String: Any] = [
            // ВАЖНО для приватности: не info.
            //
            // На уровне info ядро пишет каждое соединение вместе с адресом
            // назначения — то есть фактически историю посещений. Вывод ядра
            // перенаправлен в файл, и эта история осела бы на диске, а вместе
            // с резервной копией уехала бы в iCloud. Ошибки на уровне warn
            // по-прежнему видны, а для разбора сбоев подключения этого хватает.
            // На warn ядро молчит, пока считает, что всё хорошо, — а именно так
            // выглядит «туннель поднят, трафик не идёт». Подробный уровень
            // включается в настройках вручную и только на время разбора: на нём
            // в файл попадает каждое соединение с адресом назначения.
            "log": ["level": verbose ? "debug" : "warn", "timestamp": verbose],

            // Формат DNS начиная с 1.12: сервер задаётся полями type/server,
            // а не строкой address, как было раньше.
            "dns": [
                "servers": [
                    [
                        // DNS по TCP, а не по UDP.
                        //
                        // UDP через прокси пробрасывают далеко не все серверы:
                        // запрос уходит и не возвращается, имена не резолвятся,
                        // и страницы не открываются при живом туннеле. TCP
                        // работает через любой прокси. Шифрованный DoT здесь не
                        // берём: он требует сертификата на IP-адрес резолвера.
                        "type": "tcp",
                        "tag": "dns-remote",
                        "server": dns,
                        "detour": "proxy"
                    ],
                    [
                        // Системный резолвер, а НЕ 8.8.8.8.
                        //
                        // Через этот сервер разрешается имя самого VPN-сервера —
                        // то есть он работает ДО того, как туннель заработал, и
                        // идёт напрямую, мимо него. Раньше здесь стоял 8.8.8.8
                        // по UDP, и это оказалось плохим выбором: там, где нужен
                        // VPN, публичные резолверы по UDP как раз и режут в
                        // первую очередь. Имя сервера не разрешалось, соединение
                        // не устанавливалось — а туннель при этом рапортовал
                        // «подключено», потому что сам он поднялся. Снаружи это
                        // выглядит как «защищено, но ничего не грузится».
                        //
                        // «local» отдаёт запрос системному резолверу устройства:
                        // тому, который выдал провайдер или роутер. Он доступен
                        // всегда, и адрес сервера через него разрешается даже
                        // там, где чужие DNS недоступны.
                        "type": "local",
                        "tag": "dns-direct"
                    ]
                ],
                "rules": [
                    // Отсекаем AAAA: за прокси IPv6, как правило, нет, а система
                    // предпочитает его при наличии записи — соединения повисали
                    // бы до таймаута вместо того, чтобы сразу пойти по IPv4.
                    //
                    // Отвечаем пустым NOERROR, а не reject.
                    //
                    // reject возвращает ошибку, и это совсем другой смысл: клиент
                    // читает её как «домена не существует» и в части случаев
                    // перестаёт спрашивать IPv4 вовсе. Пустой NOERROR — штатный
                    // ответ «записи такого типа нет», после него система сразу
                    // идёт за A-записью. Отсюда и заметная часть «сайт грузится
                    // вечно» при живом туннеле.
                    [
                        "query_type": ["AAAA"],
                        "action": "predefined",
                        "rcode": "NOERROR"
                    ]
                ],
                "final": "dns-remote",

                // Кэш ответов.
                //
                // Резолвер работает по TCP через прокси, и каждый запрос — это
                // новое соединение и полный оборот до сервера. Обычная страница
                // тянет два-три десятка доменов, и без кэша всё это оплачивается
                // заново на каждой вкладке. С кэшем повторные обращения
                // отвечают мгновенно — это самая заметная прибавка к скорости
                // открытия сайтов.
                "cache_capacity": 4096,
                "disable_cache": false,
                // Общий кэш на все выходы: раздельный нужен, когда один домен
                // должен резолвиться по-разному в зависимости от маршрута, а у
                // нас маршрут один.
                "independent_cache": false,

                // Спрашиваем сразу только A-записи. Экономит половину запросов:
                // без этого система сначала спрашивает AAAA и лишь потом A.
                "strategy": "ipv4_only"
            ],

            "inbounds": [[
                "type": "tun",
                "tag": "tun-in",
                // Только IPv4. С IPv6-адресом и маршрутом туннель забирает на
                // себя весь IPv6-трафик, которому потом некуда идти.
                "address": ["172.19.0.1/30"],

                // 1400, а не 9000.
                //
                // С девятью тысячами система отдаёт в туннель огромные пакеты.
                // Дальше их надо уложить в реальный путь до сервера, где предел
                // около 1500 минус заголовки прокси и TLS. Когда это не
                // получается, пакет молча теряется: соединение устанавливается,
                // проходят первые байты — и рвётся с «network connection was
                // lost». Именно так вели себя все запросы к подписке при живом
                // туннеле, и по той же причине сайты открывались через раз.
                //
                // 1400 с запасом влезает в любой путь, включая сотовые сети.
                "mtu": 1400,
                "auto_route": true,
                "strict_route": false,
                // gvisor — пользовательский стек. На iOS обязателен: системный
                // внутри расширения недоступен.
                "stack": "gvisor"
            ]],

            // Пустой direct-выход больше не нужен: прямые соединения ядро
            // делает само, когда обходной путь не задан.
            "outbounds": [outbound],

            "route": [
                "rules": [
                    // Определяем домен по первому пакету, чтобы на сервер уходил
                    // он, а не голый IP. Таймаут укорочен: по умолчанию ядро ждёт
                    // первых данных до 300 мс, и эта задержка добавляется к
                    // КАЖДОМУ соединению. Клиент в норме шлёт TLS ClientHello
                    // сразу, так что сотни миллисекунд хватает с запасом, а на
                    // странице с тремя десятками соединений разница ощутима.
                    ["action": "sniff", "timeout": "100ms"],
                    ["protocol": "dns", "action": "hijack-dns"]
                ],
                "final": "proxy",
                "auto_detect_interface": true,
                // Обязательно с 1.12. Адрес сервера из ключа — обычно домен,
                // и разрешать его нужно НЕ через прокси: иначе замкнутый круг —
                // чтобы подключиться, нужен DNS, а DNS идёт через подключение.
                "default_domain_resolver": "dns-direct"
            ]
        ]

        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Разбор ключа в outbound

    /// Адрес и порт сервера — для замера задержки, без построения конфига.
    static func serverEndpoint(from key: String) throws -> (host: String, port: Int) {
        // Ключи с транспортом Xray этим разборщиком не строятся — он их
        // намеренно отвергает. Адрес и порт в них при этом обычные, и замер
        // задержки должен работать: без него такой сервер выглядел бы в
        // списке мёртвым, хотя подключение к нему проходит.
        if needsXray(key),
           let components = URLComponents(string: key.trimmingCharacters(in: .whitespacesAndNewlines)),
           let host = components.host, !host.isEmpty,
           let port = components.port, port > 0 {
            return (host, port)
        }

        let outbound = try makeOutbound(from: key)
        guard let host = outbound["server"] as? String,
              let port = outbound["server_port"] as? Int else {
            throw ParseError.malformed("нет адреса сервера")
        }
        return (host, port)
    }

    static func makeOutbound(from key: String) throws -> [String: Any] {
        let raw = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw ParseError.emptyKey }

        guard let schemeEnd = raw.range(of: "://") else {
            throw ParseError.malformed("нет схемы вида «vless://»")
        }
        let scheme = String(raw[raw.startIndex..<schemeEnd.lowerBound]).lowercased()

        switch scheme {
        case "vless":                 return try vless(raw)
        case "vmess":                 return try vmess(raw)
        case "trojan":                return try trojan(raw)
        case "ss", "shadowsocks":     return try shadowsocks(raw)
        case "hysteria2", "hy2":      return try hysteria2(raw)
        case "tuic":                  return try tuic(raw)
        case "socks", "socks5":       return try socks(raw)
        default:                      throw ParseError.unsupportedScheme(scheme)
        }
    }

    // MARK: - VLESS

    private static func vless(_ raw: String) throws -> [String: Any] {
        let u = try url(raw)
        let q = query(u)

        var out: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": try host(u),
            "server_port": try port(u),
            "uuid": try user(u)
        ]

        if let flow = q["flow"], !flow.isEmpty {
            out["flow"] = flow
        }
        if let tls = tlsBlock(q, defaultSNI: try host(u)) {
            out["tls"] = tls
        }
        if let transport = try transportBlock(q) {
            out["transport"] = transport
        }
        return out
    }

    // MARK: - VMESS
    //
    // vmess:// — это base64 от JSON, а не обычный URL.

    private static func vmess(_ raw: String) throws -> [String: Any] {
        let payload = String(raw.dropFirst("vmess://".count))
        guard let data = base64Decode(payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.malformed("не удалось раскодировать base64-содержимое vmess")
        }

        // В vmess-ссылках числа приходят то числом, то строкой.
        func str(_ k: String) -> String? {
            if let s = json[k] as? String { return s }
            if let n = json[k] as? NSNumber { return n.stringValue }
            return nil
        }
        func int(_ k: String) -> Int? {
            if let n = json[k] as? NSNumber { return n.intValue }
            if let s = json[k] as? String { return Int(s) }
            return nil
        }

        guard let add = str("add"), !add.isEmpty else {
            throw ParseError.malformed("в vmess нет адреса сервера")
        }
        guard let p = int("port") else {
            throw ParseError.malformed("в vmess нет порта")
        }
        guard let id = str("id"), !id.isEmpty else {
            throw ParseError.malformed("в vmess нет UUID")
        }

        var out: [String: Any] = [
            "type": "vmess",
            "tag": "proxy",
            "server": add,
            "server_port": p,
            "uuid": id,
            "alter_id": int("aid") ?? 0,
            "security": str("scy") ?? "auto"
        ]

        if (str("tls") ?? "").lowercased() == "tls" {
            var tls: [String: Any] = ["enabled": true]
            let sni = str("sni") ?? str("host") ?? add
            if !sni.isEmpty { tls["server_name"] = sni }
            out["tls"] = tls
        }

        // Транспорт разбираем тем же кодом, что и у vless/trojan.
        //
        // Раньше здесь был отдельный switch на ws/grpc/h2, и vmess с
        // httpupgrade или quic отвергался как «неподдерживаемый», хотя ядро
        // эти транспорты умеет. Приводим поля vmess-JSON к тем же именам,
        // что в query-строке ссылки, и вызываем общий разбор.
        var q: [String: String] = ["type": (str("net") ?? "tcp")]
        if let p = str("path"), !p.isEmpty {
            q["path"] = p
            // В vmess у gRPC имя сервиса лежит в том же поле path.
            q["serviceName"] = p
        }
        if let h = str("host"), !h.isEmpty { q["host"] = h }
        if let t = try transportBlock(q) {
            out["transport"] = t
        }

        return out
    }

    // MARK: - Trojan

    private static func trojan(_ raw: String) throws -> [String: Any] {
        let u = try url(raw)
        let q = query(u)

        var out: [String: Any] = [
            "type": "trojan",
            "tag": "proxy",
            "server": try host(u),
            "server_port": try port(u),
            "password": try user(u)
        ]

        // У trojan шифрование включено всегда.
        out["tls"] = tlsBlock(q, defaultSNI: try host(u), forceEnabled: true)

        if let transport = try transportBlock(q) {
            out["transport"] = transport
        }
        return out
    }

    // MARK: - Shadowsocks
    //
    // Два формата: ss://base64(method:password)@host:port
    //          и  ss://base64(method:password@host:port)

    private static func shadowsocks(_ raw: String) throws -> [String: Any] {
        let body = String(raw.dropFirst("ss://".count))
            .components(separatedBy: "#").first ?? ""
        let withoutQuery = body.components(separatedBy: "?").first ?? body

        var method = ""
        var password = ""
        var server = ""
        var serverPort = 0

        if let at = withoutQuery.lastIndex(of: "@") {
            // Формат 1: закодирована только пара method:password
            let credsPart = String(withoutQuery[withoutQuery.startIndex..<at])
            let hostPart  = String(withoutQuery[withoutQuery.index(after: at)...])

            let creds = base64Decode(credsPart).map { String(decoding: $0, as: UTF8.self) }
                ?? credsPart.removingPercentEncoding
                ?? credsPart

            guard let colon = creds.firstIndex(of: ":") else {
                throw ParseError.malformed("в ss нет пары метод:пароль")
            }
            method = String(creds[creds.startIndex..<colon])
            password = String(creds[creds.index(after: colon)...])

            guard let hostColon = hostPart.lastIndex(of: ":"),
                  let p = Int(hostPart[hostPart.index(after: hostColon)...]) else {
                throw ParseError.malformed("в ss нет порта")
            }
            server = String(hostPart[hostPart.startIndex..<hostColon])
            serverPort = p
        } else {
            // Формат 2: закодирована вся строка целиком
            guard let data = base64Decode(withoutQuery) else {
                throw ParseError.malformed("не удалось раскодировать base64 в ss")
            }
            let decoded = String(decoding: data, as: UTF8.self)

            guard let at = decoded.lastIndex(of: "@") else {
                throw ParseError.malformed("в ss нет разделителя @")
            }
            let creds = String(decoded[decoded.startIndex..<at])
            let hostPart = String(decoded[decoded.index(after: at)...])

            guard let colon = creds.firstIndex(of: ":") else {
                throw ParseError.malformed("в ss нет пары метод:пароль")
            }
            method = String(creds[creds.startIndex..<colon])
            password = String(creds[creds.index(after: colon)...])

            guard let hostColon = hostPart.lastIndex(of: ":"),
                  let p = Int(hostPart[hostPart.index(after: hostColon)...]) else {
                throw ParseError.malformed("в ss нет порта")
            }
            server = String(hostPart[hostPart.startIndex..<hostColon])
            serverPort = p
        }

        // IPv6 в ссылках пишут в скобках.
        server = server.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        guard !server.isEmpty else { throw ParseError.malformed("в ss нет адреса сервера") }

        return [
            "type": "shadowsocks",
            "tag": "proxy",
            "server": server,
            "server_port": serverPort,
            "method": method,
            "password": password
        ]
    }

    // MARK: - Hysteria2

    private static func hysteria2(_ raw: String) throws -> [String: Any] {
        let u = try url(raw)
        let q = query(u)

        // Вычисляем заранее: внутри выражения с ?? бросающий вызов не годится.
        let server = try host(u)

        var out: [String: Any] = [
            "type": "hysteria2",
            "tag": "proxy",
            "server": server,
            "server_port": try port(u),
            "password": u.user?.removingPercentEncoding ?? ""
        ]

        var tls: [String: Any] = ["enabled": true]
        tls["server_name"] = q["sni"] ?? q["peer"] ?? server
        if q["insecure"] == "1" || q["allowInsecure"] == "1" {
            tls["insecure"] = true
        }
        if let alpn = q["alpn"], !alpn.isEmpty {
            tls["alpn"] = alpn.components(separatedBy: ",")
        }
        out["tls"] = tls

        if let obfs = q["obfs"], obfs == "salamander", let pw = q["obfs-password"] {
            out["obfs"] = ["type": "salamander", "password": pw]
        }
        return out
    }

    // MARK: - TUIC

    private static func tuic(_ raw: String) throws -> [String: Any] {
        let u = try url(raw)
        let q = query(u)

        // tuic://uuid:password@host:port
        let uuid = u.user?.removingPercentEncoding ?? ""
        let password = u.password?.removingPercentEncoding ?? ""

        guard !uuid.isEmpty else { throw ParseError.malformed("в tuic нет UUID") }

        let server = try host(u)

        var out: [String: Any] = [
            "type": "tuic",
            "tag": "proxy",
            "server": server,
            "server_port": try port(u),
            "uuid": uuid,
            "password": password,
            "congestion_control": q["congestion_control"] ?? "bbr"
        ]

        var tls: [String: Any] = ["enabled": true]
        tls["server_name"] = q["sni"] ?? server
        if q["allow_insecure"] == "1" || q["insecure"] == "1" {
            tls["insecure"] = true
        }
        if let alpn = q["alpn"], !alpn.isEmpty {
            tls["alpn"] = alpn.components(separatedBy: ",")
        }
        out["tls"] = tls

        return out
    }

    // MARK: - SOCKS

    private static func socks(_ raw: String) throws -> [String: Any] {
        let u = try url(raw)

        var out: [String: Any] = [
            "type": "socks",
            "tag": "proxy",
            "server": try host(u),
            "server_port": try port(u),
            "version": "5"
        ]
        if let user = u.user?.removingPercentEncoding, !user.isEmpty {
            out["username"] = user
            out["password"] = u.password?.removingPercentEncoding ?? ""
        }
        return out
    }

    // MARK: - Общие куски

    /// TLS-блок из query-параметров ссылки, включая Reality.
    private static func tlsBlock(_ q: [String: String],
                                 defaultSNI: String,
                                 forceEnabled: Bool = false) -> [String: Any]? {
        let security = (q["security"] ?? "").lowercased()
        let enabled = forceEnabled || security == "tls" || security == "reality" || security == "xtls"
        guard enabled else { return nil }

        var tls: [String: Any] = ["enabled": true]

        let sni = q["sni"] ?? q["peer"] ?? q["host"] ?? defaultSNI
        if !sni.isEmpty { tls["server_name"] = sni }

        if q["allowInsecure"] == "1" || q["insecure"] == "1" {
            tls["insecure"] = true
        }
        if let alpn = q["alpn"], !alpn.isEmpty {
            tls["alpn"] = alpn.components(separatedBy: ",")
        }
        if let fp = q["fp"], !fp.isEmpty {
            tls["utls"] = ["enabled": true, "fingerprint": fp]
        }
        if security == "reality", let pbk = q["pbk"], !pbk.isEmpty {
            var reality: [String: Any] = ["enabled": true, "public_key": pbk]
            if let sid = q["sid"], !sid.isEmpty { reality["short_id"] = sid }
            tls["reality"] = reality
            // Reality без utls не работает — подставляем отпечаток по умолчанию.
            if tls["utls"] == nil {
                tls["utls"] = ["enabled": true, "fingerprint": "chrome"]
            }
        }
        return tls
    }

    /// Транспорт (ws / grpc / http) из query-параметров.
    /// Транспорты, которые умеет ядро. Всё остальное честнее отвергнуть, чем
    /// подключаться «как получится».
    static let supportedTransports: Set<String> = [
        "", "tcp", "raw", "none", "ws", "grpc", "http", "h2", "httpupgrade", "quic"
    ]

    /// Транспорты, которые умеет только Xray. Их исполняет второе ядро —
    /// см. XrayBridge, там же объяснено, почему без него никак.
    static let xrayTransports: Set<String> = ["xhttp", "splithttp"]

    static func supports(transport: String) -> Bool {
        let transport = transport.lowercased()
        return supportedTransports.contains(transport)
            || xrayTransports.contains(transport)
    }

    /// Нужно ли для этого ключа поднимать Xray.
    static func needsXray(_ key: String) -> Bool {
        guard let transport = try? transportName(of: key) else { return false }
        return xrayTransports.contains(transport)
    }

    /// Имя транспорта прямо из ключа — без построения всего конфига.
    static func transportName(of key: String) throws -> String {
        let raw = key.trimmingCharacters(in: .whitespacesAndNewlines)

        if raw.lowercased().hasPrefix("vmess://") {
            guard let data = base64Decode(String(raw.dropFirst(8))),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let net = json["net"] as? String else {
                return "tcp"
            }
            return net.lowercased()
        }

        guard let components = URLComponents(string: raw) else { return "tcp" }
        let type = components.queryItems?.first { $0.name == "type" }?.value ?? ""
        return type.isEmpty ? "tcp" : type.lowercased()
    }

    /// Путь транспорта. Ссылки приходят с процентным кодированием, а vmess-JSON
    /// — без него; `removingPercentEncoding` на строке с одиночным «%» вернул бы
    /// nil, поэтому при неудаче берём исходное значение как есть.
    private static func path(_ q: [String: String]) -> String {
        guard let raw = q["path"], !raw.isEmpty else { return "/" }
        return raw.removingPercentEncoding ?? raw
    }

    private static func transportBlock(_ q: [String: String]) throws -> [String: Any]? {
        switch (q["type"] ?? "tcp").lowercased() {
        case "ws":
            var t: [String: Any] = ["type": "ws"]
            t["path"] = path(q)
            if let h = q["host"], !h.isEmpty { t["headers"] = ["Host": h] }
            return t
        case "grpc":
            return ["type": "grpc", "service_name": q["serviceName"] ?? ""]
        case "http", "h2":
            var t: [String: Any] = ["type": "http"]
            t["path"] = path(q)
            if let h = q["host"], !h.isEmpty { t["host"] = h.components(separatedBy: ",") }
            return t
        case "httpupgrade":
            var t: [String: Any] = ["type": "httpupgrade"]
            t["path"] = path(q)
            if let h = q["host"], !h.isEmpty { t["host"] = h }
            return t
        case "quic":
            return ["type": "quic"]
        case "", "tcp", "raw", "none":
            // Без транспорта — обычный TCP, это норма.
            return nil
        case let other:
            // xhttp, splithttp, kcp и прочее из Xray: ядро их не умеет.
            //
            // Раньше такой транспорт молча игнорировался, и приложение
            // подключалось как по обычному TCP. Сервер этого не понимал,
            // соединение зависало, а выглядело как «эта страна не работает».
            // Лучше честная ошибка.
            throw ParseError.unsupportedTransport(other)
        }
    }

    // MARK: - Мелкие помощники

    private static func url(_ raw: String) throws -> URLComponents {
        guard let u = URLComponents(string: raw) else {
            throw ParseError.malformed("ссылка не разбирается")
        }
        return u
    }

    private static func host(_ u: URLComponents) throws -> String {
        guard let h = u.host, !h.isEmpty else {
            throw ParseError.malformed("нет адреса сервера")
        }
        return h.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func port(_ u: URLComponents) throws -> Int {
        guard let p = u.port, p > 0 else {
            throw ParseError.malformed("нет порта")
        }
        return p
    }

    private static func user(_ u: URLComponents) throws -> String {
        guard let user = u.user?.removingPercentEncoding, !user.isEmpty else {
            throw ParseError.malformed("нет UUID/пароля")
        }
        return user
    }

    private static func query(_ u: URLComponents) -> [String: String] {
        var result: [String: String] = [:]
        for item in u.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    /// base64 в ссылках бывает и обычный, и url-safe, и без хвостовых «=».
    private static func base64Decode(_ s: String) -> Data? {
        var t = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = t.count % 4
        if remainder > 0 {
            t += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: t)
    }
}
