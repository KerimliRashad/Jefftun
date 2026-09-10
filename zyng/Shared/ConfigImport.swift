import Foundation

/// Превращает готовый конфиг Xray или sing-box в наши ссылки-ключи.
///
/// Зачем это нужно. Панели подписок отдают разным клиентам разное — и решают
/// по User-Agent. По одной и той же ссылке мы получали вот что:
///
///     Happ, v2rayNG, Streisand → JSON-конфиг Xray, 22 КБ: vless + Reality
///     SFI                      → JSON-конфиг sing-box
///     Shadowrocket, sing-box   → текст с шестью ss:// — устаревшими
///
/// Наш загрузчик искал в ответе строки вида «vless://». В JSON таких строк нет,
/// поэтому он находил ноль ключей и откатывался на последний вариант — шесть
/// давно выключенных ss-серверов. Со стороны это выглядело так: «в Happ моя
/// подписка работает, в Zyng те же серверы не отвечают». Ядро было ни при чём.
///
/// Здесь мы разбираем оба формата и собираем из них обычные ссылки, с которыми
/// дальше работает всё остальное приложение.
enum ConfigImport {

    /// Ключи из JSON-конфига. Пустой массив — это не наш формат.
    static func keys(fromJSON text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") || trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        // Массив — это набор профилей Xray, по одному на сервер: именно так
        // отдаёт панель, и имя сервера лежит в поле remarks.
        var result: [String] = []
        if let list = object as? [[String: Any]] {
            result = list.flatMap { keys(fromConfig: $0) }
        } else if let single = object as? [String: Any] {
            result = keys(fromConfig: single)
        }

        // Повторы выбрасываем.
        //
        // Один и тот же сервер нередко описан в нескольких профилях сразу —
        // например, как запасной. В списке он выглядел бы двойником, который
        // ничем не отличается от соседа.
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    private static func keys(fromConfig config: [String: Any]) -> [String] {
        guard let outbounds = config["outbounds"] as? [[String: Any]] else { return [] }

        // Имя профиля. У Xray оно в remarks, у sing-box его нет вовсе —
        // тогда возьмём тег самого выхода.
        let title = (config["remarks"] as? String) ?? ""

        // Сколько настоящих выходов в профиле: от этого зависит, надо ли
        // дописывать к имени транспорт.
        let real = outbounds.filter { outbound in
            let kind = ((outbound["protocol"] as? String)
                        ?? (outbound["type"] as? String) ?? "").lowercased()
            return !["freedom", "direct", "blackhole", "block", "dns", "loopback"].contains(kind)
        }
        let needsSuffix = real.count > 1

        var result: [String] = []
        for outbound in outbounds {
            // Xray называет поле protocol, sing-box — type.
            let kind = ((outbound["protocol"] as? String)
                        ?? (outbound["type"] as? String) ?? "").lowercased()

            // Служебные выходы серверами не являются.
            guard !["freedom", "direct", "blackhole", "block", "dns", "loopback"].contains(kind) else {
                continue
            }

            var name = title.isEmpty ? ((outbound["tag"] as? String) ?? "") : title

            // Имя профиля одно на все его выходы, а выходов бывает три:
            // vless по tcp, он же по xhttp и Hysteria 2. В списке получались
            // три строки «Netherlands — быстрый», неотличимые друг от друга, —
            // и человек не понимал, чем они разные и какую выбирать.
            if needsSuffix, let mark = shortMark(of: outbound, kind: kind) {
                name = name.isEmpty ? mark : "\(name) · \(mark)"
            }

            if let link = link(from: outbound, kind: kind, name: name) {
                result.append(link)
            }
        }
        return result
    }

    /// Короткая пометка транспорта для имени: XHTTP, HY2, WS и подобное.
    /// Для обычного tcp пометка не нужна — это случай по умолчанию.
    private static func shortMark(of outbound: [String: Any], kind: String) -> String? {
        if kind == "hysteria" || kind == "hysteria2" { return "HY2" }

        let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        let network = ((stream["network"] as? String)
                       ?? (outbound["transport"] as? [String: Any])?["type"] as? String
                       ?? "tcp").lowercased()

        switch network {
        case "tcp", "raw", "none", "": return nil
        case "xhttp", "splithttp":     return "XHTTP"
        case "httpupgrade":            return "HTTPUpgrade"
        default:                       return network.uppercased()
        }
    }

    // MARK: - Сборка ссылки

    private static func link(from outbound: [String: Any],
                             kind: String,
                             name: String) -> String? {
        // Адрес и порт лежат по-разному: у Xray внутри settings, у sing-box
        // прямо в выходе.
        let (host, port, user) = endpoint(of: outbound, kind: kind)
        guard !host.isEmpty, port > 0 else { return nil }

        let tag = name.isEmpty ? "" : "#" + (name.addingPercentEncoding(
            withAllowedCharacters: .urlFragmentAllowed) ?? name)

        switch kind {
        case "vless":
            guard !user.isEmpty else { return nil }
            let query = streamQuery(of: outbound, flow: flow(of: outbound))
            return "vless://\(user)@\(host):\(port)?\(query)\(tag)"

        case "trojan":
            guard !user.isEmpty else { return nil }
            let query = streamQuery(of: outbound, flow: nil)
            return "trojan://\(user)@\(host):\(port)?\(query)\(tag)"

        case "vmess":
            return vmess(from: outbound, host: host, port: port, id: user, name: name)

        case "shadowsocks":
            return shadowsocks(from: outbound, host: host, port: port, name: tag)

        case "hysteria", "hysteria2":
            // Xray в сборке Happ описывает Hysteria 2 своим способом: пароль
            // лежит в streamSettings.hysteriaSettings.auth.
            let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
            let hysteria = stream["hysteriaSettings"] as? [String: Any] ?? [:]
            let password = (hysteria["auth"] as? String)
                ?? (outbound["password"] as? String) ?? user
            guard !password.isEmpty else { return nil }

            var parts: [String] = []
            if let sni = serverName(of: outbound), !sni.isEmpty { parts.append("sni=\(sni)") }
            if let alpn = alpn(of: outbound) { parts.append("alpn=\(alpn)") }
            let query = parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
            return "hysteria2://\(escape(password))@\(host):\(port)\(query)\(tag)"

        default:
            return nil
        }
    }

    /// Адрес, порт и «пользователь» — UUID для vless/vmess, пароль для trojan.
    private static func endpoint(of outbound: [String: Any],
                                 kind: String) -> (String, Int, String) {
        // sing-box: поля лежат прямо в выходе.
        if let host = outbound["server"] as? String,
           let port = intValue(outbound["server_port"]) {
            let user = (outbound["uuid"] as? String)
                ?? (outbound["password"] as? String) ?? ""
            return (host, port, user)
        }

        let settings = outbound["settings"] as? [String: Any] ?? [:]

        // vless и vmess: settings.vnext[0]
        if let vnext = (settings["vnext"] as? [[String: Any]])?.first {
            let host = vnext["address"] as? String ?? ""
            let port = intValue(vnext["port"]) ?? 0
            let users = vnext["users"] as? [[String: Any]] ?? []
            let id = (users.first?["id"] as? String) ?? ""
            return (host, port, id)
        }

        // trojan и shadowsocks: settings.servers[0]
        if let server = (settings["servers"] as? [[String: Any]])?.first {
            let host = server["address"] as? String ?? ""
            let port = intValue(server["port"]) ?? 0
            let password = (server["password"] as? String) ?? ""
            return (host, port, password)
        }

        // Hysteria в исполнении Happ: адрес прямо в settings.
        if let host = settings["address"] as? String {
            return (host, intValue(settings["port"]) ?? 0, "")
        }

        return ("", 0, "")
    }

    private static func flow(of outbound: [String: Any]) -> String? {
        if let flow = outbound["flow"] as? String, !flow.isEmpty { return flow }
        let settings = outbound["settings"] as? [String: Any] ?? [:]
        let users = (settings["vnext"] as? [[String: Any]])?.first?["users"] as? [[String: Any]]
        let flow = users?.first?["flow"] as? String
        return (flow?.isEmpty ?? true) ? nil : flow
    }

    private static func serverName(of outbound: [String: Any]) -> String? {
        let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        if let reality = stream["realitySettings"] as? [String: Any],
           let name = reality["serverName"] as? String, !name.isEmpty {
            return name
        }
        if let tls = stream["tlsSettings"] as? [String: Any],
           let name = tls["serverName"] as? String, !name.isEmpty {
            return name
        }
        // sing-box
        if let tls = outbound["tls"] as? [String: Any],
           let name = tls["server_name"] as? String, !name.isEmpty {
            return name
        }
        return nil
    }

    private static func alpn(of outbound: [String: Any]) -> String? {
        let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        if let tls = stream["tlsSettings"] as? [String: Any],
           let list = tls["alpn"] as? [String], !list.isEmpty {
            return escape(list.joined(separator: ","))
        }
        if let tls = outbound["tls"] as? [String: Any],
           let list = tls["alpn"] as? [String], !list.isEmpty {
            return escape(list.joined(separator: ","))
        }
        return nil
    }

    /// Параметры транспорта и шифрования — то, что в ссылке идёт после «?».
    private static func streamQuery(of outbound: [String: Any], flow: String?) -> String {
        let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        var parts: [String] = []

        let network = ((stream["network"] as? String)
                       ?? (outbound["transport"] as? [String: Any])?["type"] as? String
                       ?? "tcp").lowercased()
        parts.append("type=\(network)")

        // Шифрование.
        let security = (stream["security"] as? String ?? "").lowercased()
        let reality = stream["realitySettings"] as? [String: Any]
        if security == "reality" || reality != nil {
            parts.append("security=reality")
            if let key = reality?["publicKey"] as? String, !key.isEmpty {
                parts.append("pbk=\(escape(key))")
            }
            if let sid = reality?["shortId"] as? String, !sid.isEmpty {
                parts.append("sid=\(escape(sid))")
            }
            if let spider = reality?["spiderX"] as? String, !spider.isEmpty {
                parts.append("spx=\(escape(spider))")
            }
        } else if security == "tls" || security == "xtls" {
            parts.append("security=tls")
        }

        if let sni = serverName(of: outbound), !sni.isEmpty {
            parts.append("sni=\(escape(sni))")
        }

        // Отпечаток браузера. Reality без него не работает.
        let fingerprint = (reality?["fingerprint"] as? String)
            ?? ((stream["tlsSettings"] as? [String: Any])?["fingerprint"] as? String)
        if let fingerprint, !fingerprint.isEmpty {
            parts.append("fp=\(escape(fingerprint))")
        }

        if let alpn = alpn(of: outbound) { parts.append("alpn=\(alpn)") }
        if let flow, !flow.isEmpty { parts.append("flow=\(escape(flow))") }

        // Настройки самого транспорта.
        switch network {
        case "ws", "httpupgrade":
            let ws = (stream["wsSettings"] ?? stream["httpupgradeSettings"]) as? [String: Any] ?? [:]
            if let path = ws["path"] as? String, !path.isEmpty {
                parts.append("path=\(escape(path))")
            }
            let host = (ws["host"] as? String)
                ?? ((ws["headers"] as? [String: Any])?["Host"] as? String)
            if let host, !host.isEmpty { parts.append("host=\(escape(host))") }

        case "grpc":
            let grpc = stream["grpcSettings"] as? [String: Any] ?? [:]
            if let name = grpc["serviceName"] as? String, !name.isEmpty {
                parts.append("serviceName=\(escape(name))")
            }

        case "xhttp", "splithttp":
            let xhttp = (stream["xhttpSettings"] ?? stream["splithttpSettings"]) as? [String: Any] ?? [:]
            if let path = xhttp["path"] as? String, !path.isEmpty {
                parts.append("path=\(escape(path))")
            }
            if let host = xhttp["host"] as? String, !host.isEmpty {
                parts.append("host=\(escape(host))")
            }
            if let mode = xhttp["mode"] as? String, !mode.isEmpty {
                parts.append("mode=\(escape(mode))")
            }

        default:
            break
        }

        return parts.joined(separator: "&")
    }

    private static func vmess(from outbound: [String: Any],
                              host: String, port: Int, id: String, name: String) -> String? {
        guard !id.isEmpty else { return nil }

        let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        let network = (stream["network"] as? String ?? "tcp").lowercased()
        let ws = stream["wsSettings"] as? [String: Any] ?? [:]

        var json: [String: Any] = [
            "v": "2", "ps": name, "add": host, "port": String(port), "id": id,
            "aid": "0", "net": network, "type": "none",
            "tls": (stream["security"] as? String) == "tls" ? "tls" : ""
        ]
        if let path = ws["path"] as? String { json["path"] = path }
        if let sni = serverName(of: outbound) { json["host"] = sni; json["sni"] = sni }

        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return "vmess://" + data.base64EncodedString()
    }

    private static func shadowsocks(from outbound: [String: Any],
                                    host: String, port: Int, name: String) -> String? {
        let settings = outbound["settings"] as? [String: Any] ?? [:]
        let server = (settings["servers"] as? [[String: Any]])?.first ?? [:]

        let method = (outbound["method"] as? String)
            ?? (server["method"] as? String) ?? ""
        let password = (outbound["password"] as? String)
            ?? (server["password"] as? String) ?? ""
        guard !method.isEmpty, !password.isEmpty else { return nil }

        let creds = Data("\(method):\(password)".utf8).base64EncodedString()
        return "ss://\(creds)@\(host):\(port)\(name)"
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? text
    }
}

private extension CharacterSet {
    /// Значение параметра: «&» и «=» внутри него ломали бы разбор ссылки.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?#+")
        return set
    }()
}
