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
    /// Выбора DNS больше нет — и не должно быть.
    ///
    /// В настройках стоял список из четырёх резолверов с подписями вроде
    /// «блокируется у части провайдеров». Подписи были про домашнего
    /// провайдера, а запрос внутри туннеля уходит НЕ от телефона, а от
    /// VPN-сервера — блокировки провайдера к нему отношения не имеют. То есть
    /// пользователь выбирал по неверному признаку, а неудачный выбор ронял
    /// резолвинг целиком: туннель поднят, ошибок нет, сайты не открываются.
    /// В OneXray и Happ такой настройки на виду нет по той же причине.
    static func makeConfig(from key: String,
                           logPath: String? = nil,
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
                "server_port": XrayBridge.socksPort
                // Без domain_strategy.
                //
                // Прокси не должен разрешать имена сам: имя целиком уезжает на
                // сервер, и разрешает его сервер. Домен sing-box узнаёт из
                // sniff и передаёт в SOCKS как есть. Так работают Happ и
                // OneXray.
            ]
        } else {
            outbound = try makeOutbound(from: key)
        }

        // Журнал ядра — в файл, явно.
        //
        // Без этого поля sing-box внутри расширения не пишет никуда, куда мы
        // могли бы заглянуть: строки уходят его служебной части, а та рассылает
        // их подключённым клиентам. Приложение таким клиентом не было — отсюда
        // и вечное «Ядро ничего не записало» при полностью исправном ядре.
        var log: [String: Any] = [
            // Уровень warn — и этого теперь достаточно.
            //
            // Пока журнал вообще никуда не писался (поле output не задавалось),
            // на warn мы не видели ничего и подняли уровень до info. Но info
            // пишет КАЖДОЕ соединение вместе с адресом назначения — то есть
            // историю посещений, и она оседала бы в файле.
            //
            // Оказалось, что цена была лишней: строки, ради которых всё
            // затевалось, — «dial ...: i/o timeout» — идут уровнем ERROR и на
            // warn видны прекрасно. Пропадает только перечисление доменов,
            // которого нам и не нужно.
            //
            // Подробности включаются вручную, в настройках, и только на время
            // разбора.
            "level": verbose ? "debug" : "warn",
            "timestamp": true
        ]
        if let logPath { log["output"] = logPath }

        let config: [String: Any] = [
            "log": log,

            // DNS. Ничего лишнего.
            //
            // Здесь долго копились «улучшения»: кэш, отсечение AAAA пустым
            // ответом, ipv4_only, таймаут сниффинга. Каждое по отдельности
            // выглядело разумно, а вместе они совпали с тем, что туннель стал
            // подниматься и не пропускать трафик. Возвращаю простую схему,
            // которая работала: два сервера и один запасной путь.
            "dns": [
                "servers": [
                    [
                        // DNS поверх HTTPS, а не голый TCP на 53-й порт.
                        //
                        // Через прокси запрос уходит наружу с САМОГО сервера, а
                        // на серверах исходящий 53-й порт закрывают сплошь и
                        // рядом: и хостинги режут его от спама, и админы сами.
                        // Тогда запрос уходит и не возвращается, ни одно имя не
                        // разрешается, и ни одна страница не открывается — при
                        // живом туннеле и без единой ошибки. Ровно эта картина
                        // у нас и была: не грузились captive.apple.com,
                        // gstatic.com, cp.cloudflare.com — то есть ИМЕНА.
                        //
                        // DoH идёт по 443. Этот порт открыт везде, иначе сервер
                        // и сам бы не работал. Заодно запрос шифрован целиком.
                        // Адрес зашит: 1.1.1.1 по HTTPS. Запрос идёт с
                        // VPN-сервера, поэтому «у меня Cloudflare блокируют»
                        // здесь не работает — блокировки домашнего провайдера
                        // до этого запроса не дотягиваются.
                        "type": "https",
                        "tag": "dns-remote",
                        "server": "1.1.1.1",
                        "path": "/dns-query",
                        "detour": "proxy"
                    ],
                    [
                        // Системный резолвер — им ядро разрешает имя самого
                        // VPN-сервера, пока туннеля ещё нет.
                        //
                        // Системный он намеренно. На сотовой связи телефону
                        // выдают только IPv6, а до IPv4-серверов пускают через
                        // NAT64 — подставить нужный адрес умеет лишь система,
                        // и только по имени. Свой резолвер здесь всё сломал бы:
                        // он вернул бы настоящий IPv4, к которому в такой сети
                        // нет маршрута.
                        "type": "local",
                        "tag": "dns-direct"
                    ]
                ],
                "final": "dns-remote"
            ],

            "inbounds": [[
                "type": "tun",
                "tag": "tun-in",
                // Только IPv4. С IPv6-адресом и маршрутом туннель забирает на
                // себя весь IPv6-трафик, которому потом некуда идти.
                "address": ["172.19.0.1/30"],

                // 9000 — как было. Значение из мобильных сборок sing-box.
                //
                // Я снижал его до 1400, подозревая потерю крупных пакетов, но
                // подтверждения этому так и не нашлось, а неприятности начались
                // примерно тогда же. Возвращаю проверенное.
                "mtu": 9000,
                "auto_route": true,
                "strict_route": false,
                // gvisor — пользовательский стек. На iOS обязателен: системный
                // внутри расширения недоступен.
                "stack": "gvisor"
            ]],

            "outbounds": [outbound],

            "route": [
                "rules": [
                    // Определяем домен по первому пакету, чтобы на сервер уходил
                    // он, а не голый IP. Без своего таймаута: подобранная мной
                    // сотня миллисекунд экономила немного, а рисковала обрывать
                    // распознавание на медленной сети.
                    ["action": "sniff"],
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
        // Сначала полноценный разбор — он умеет все форматы, включая base64
        // внутри vmess и ss. URLComponents тут только запасной вариант: для
        // ключей, которые исполняет Xray, наш разборщик конфига может и
        // отказать, а адрес в них всё равно обычный.
        if let outbound = try? makeOutbound(from: key),
           let host = outbound["server"] as? String,
           let port = outbound["server_port"] as? Int,
           !host.isEmpty, port > 0 {
            return (host, port)
        }

        if let components = URLComponents(string: key.trimmingCharacters(in: .whitespacesAndNewlines)),
           let host = components.host, !host.isEmpty,
           let port = components.port, port > 0 {
            return (host, port)
        }

        throw ParseError.malformed("нет адреса сервера")
    }

    // Подстановка готового адреса вместо имени отсюда УБРАНА.
    //
    // Она появилась против подмены DNS оператором — версия оказалась неверной:
    // защищённый резолвер вернул ровно тот же адрес, что и оператор. А вред
    // выяснился позже и был серьёзным.
    //
    // Сотовые сети раздают телефону только IPv6, а до IPv4-серверов пускают
    // через NAT64: система подставляет нужный адрес сама, но делает это ТОЛЬКО
    // когда ей дают имя. Готовому числовому IPv4 помочь нечем — маршрута к нему
    // в такой сети нет. Отсюда и картина «на Wi-Fi работает, на 5G ни один
    // сервер не отвечает».
    //
    // Имя разрешает само ядро через dns-direct, и оно же попадает в TLS. Наш
    // резолвер остался ровно для одного — узнать адреса, чтобы исключить их из
    // маршрутов туннеля; там нужны именно числа.

    /// Числовые адреса имени: (IPv4, IPv6).
    ///
    /// Нужны ровно для одного — исключить сервер из маршрутов туннеля. Там без
    /// чисел никак: маршрут задаётся адресом, а не именем.
    ///
    /// Подключаться по этим числам НЕЛЬЗЯ — см. пояснение выше про NAT64.
    static func resolve(_ host: String) -> (v4: [String], v6: [String]) {
        let addresses = SecureDNS.resolveSync(host)
        return (addresses.filter { !$0.contains(":") },
                addresses.filter { $0.contains(":") })
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

        // Обёртка (plugin) из строки запроса.
        //
        // Здесь всё, что после «?», раньше просто выбрасывалось. А именно там
        // у ss:// живёт plugin — v2ray-plugin, obfs и подобные: сервер ждёт,
        // что трафик придёт завёрнутым, скажем, в веб-сокет. Без обёртки мы
        // подключались голым Shadowsocks: сервер такого не понимает и молчит.
        // Снаружи это выглядит как «туннель есть, трафика нет, ошибок нет» —
        // самая непонятная из всех неисправностей.
        //
        // Формат значения: «имя;опция=значение;опция=значение».
        var plugin = ""
        var pluginOpts = ""
        if let q = body.components(separatedBy: "?").dropFirst().first {
            for pair in q.components(separatedBy: "&") {
                let parts = pair.components(separatedBy: "=")
                guard parts.count >= 2, parts[0] == "plugin" else { continue }
                let value = parts.dropFirst().joined(separator: "=")
                    .removingPercentEncoding ?? ""
                if let semi = value.firstIndex(of: ";") {
                    plugin = String(value[value.startIndex..<semi])
                    pluginOpts = String(value[value.index(after: semi)...])
                } else {
                    plugin = value
                }
            }
        }

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

        var out: [String: Any] = [
            "type": "shadowsocks",
            "tag": "proxy",
            "server": server,
            "server_port": serverPort,
            "method": method,
            "password": password
        ]
        if !plugin.isEmpty {
            out["plugin"] = plugin
            if !pluginOpts.isEmpty { out["plugin_opts"] = pluginOpts }
        }
        return out
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
    /// Транспорты, которые встречаются в ссылках. Все их ведёт Xray.
    ///
    /// Список раньше перечислял то, что умеет sing-box, и всё остальное
    /// приложение честно отвергало. Теперь разговор с сервером ведёт Xray, а он
    /// знает их все — включая xhttp и kcp, которых в sing-box нет вовсе.
    static let supportedTransports: Set<String> = [
        "", "tcp", "raw", "none", "ws", "grpc", "http", "h2", "httpupgrade",
        "quic", "xhttp", "splithttp", "kcp", "mkcp", "domainsocket", "ds"
    ]

    /// Транспорты, которых в sing-box нет. Только их исполняет Xray —
    /// см. XrayBridge, там же объяснено, почему без него никак.
    static let xrayTransports: Set<String> = [
        "xhttp", "splithttp", "kcp", "mkcp", "domainsocket", "ds"
    ]

    static func supports(transport: String) -> Bool {
        let transport = transport.lowercased()
        return supportedTransports.contains(transport)
            || xrayTransports.contains(transport)
    }

    /// Вести ли этот ключ через Xray.
    ///
    /// Только те транспорты, которых в sing-box нет физически.
    ///
    /// В сборке 59 я развернул это правило наоборот: Xray вёл ВСЁ, кроме
    /// hysteria и tuic. Рассуждение было такое — раз ключ работает в клиентах
    /// на Xray, пусть и у нас его ведёт Xray. Рассуждение оказалось неверным,
    /// и вот почему.
    ///
    /// sing-box умеет привязывать исходящий сокет к настоящему сетевому
    /// интерфейсу — у него для этого есть auto_detect_interface. Xray внутри
    /// расширения так не умеет: он просто открывает соединение, а маршрут по
    /// умолчанию после подъёма туннеля — сам туннель. Пока через Xray шёл один
    /// xhttp, это всплывало редко. Когда он стал вести все ключи, круг
    /// замкнулся на каждом, и в журнале это видно дословно:
    ///
    ///     155.212.204.140:1234 ... interface: utun5 ... already failing
    ///
    /// vless, vmess, trojan и shadowsocks sing-box поддерживает полностью,
    /// вместе с reality, ws, grpc, http и httpupgrade, и ведёт их сам —
    /// без петли. Xray остаётся ровно там, где он незаменим.
    static func needsXray(_ key: String) -> Bool {
        guard let transport = try? transportName(of: key) else { return false }
        return xrayTransports.contains(transport.lowercased())
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
