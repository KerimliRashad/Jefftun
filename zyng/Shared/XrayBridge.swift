import Foundation

// Оба ядра лежат в одной библиотеке: gomobile кладёт в каждую полную копию
// среды выполнения Go, и две таких линковщик в один бинарник не пускает.
// Приставки при этом остаются разными — Libbox* и LibXray*.
#if canImport(Libcore)
import Libcore
#endif

/// Мост к ядру Xray.
///
/// Зачем оно вообще нужно, если есть sing-box.
///
/// Транспорт xhttp (он же splithttp) придуман в Xray и существует только там.
/// В sing-box его нет ни в одной версии — я проверил исходники 1.13.19: слов
/// «xhttp» и «splithttp» там нет во всём репозитории, транспортов ровно пять:
/// http, ws, quic, grpc, httpupgrade. Поэтому ключи с xhttp невозможно было
/// «починить» — их нечем было исполнить.
///
/// Как устроено соединение.
///
/// Туннель по-прежнему держит sing-box: он забирает пакеты устройства, ведёт
/// TCP/IP-стек и DNS. Меняется только то, куда он отдаёт трафик. Для обычного
/// ключа — прямо на сервер, как раньше. Для ключа с xhttp — в локальный SOCKS
/// на 127.0.0.1, который поднимает Xray, а уже он говорит с сервером на своём
/// транспорте.
///
/// Такое разделение выбрано не от красоты: у libXray нет и не было работы с
/// файловым дескриптором туннеля — в его исходниках нет ни одного упоминания
/// tun или fd. Xray умеет принимать соединения, но не умеет забирать пакеты у
/// системы. У sing-box ровно наоборот всё на месте. Каждый делает то, что
/// умеет, и главное — путь обычных ключей не меняется вовсе: если с Xray
/// что-то не так, это не может сломать то, что работало.
enum XrayBridge {

    /// Порт локального SOCKS между двумя ядрами.
    ///
    /// Фиксированный, а не запрошенный у системы: оба конца поднимаются внутри
    /// одного процесса расширения, слушается только петля, и наружу этот порт
    /// не виден. Число из верхней части диапазона — там не встретишь ничего
    /// стандартного.
    static let socksPort = 10808

    /// Версия протокола libXray. Соответствует тегу, закреплённому в core/go.mod.
    private static let apiVersion = 1

    enum Failure: LocalizedError {
        case unavailable
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return tr("Ядро Xray не собрано. Выполни ./build-core.sh",
                          "The Xray core is not built. Run ./build-core.sh")
            case .rejected(let why):
                return tr("Xray отверг конфигурацию: \(why)",
                          "Xray rejected the configuration: \(why)")
            }
        }
    }

    /// Собрано ли ядро. Фреймворк в git не хранится — он большой и
    /// пересобирается скриптом, поэтому его может не быть.
    ///
    /// Списком поддерживаемых транспортов это НЕ управляет, и намеренно.
    /// Фреймворк слинкован только с расширением туннеля, а список читает ещё и
    /// приложение — там canImport дал бы false, и один и тот же ключ считался
    /// бы поддержанным в одном процессе и нет в другом. Пусть лучше при
    /// подключении будет внятная ошибка «ядро не собрано», чем сервер, молча
    /// пропавший из списка.
    static var isAvailable: Bool {
        #if canImport(Libcore)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Вызовы

    /// Весь API libXray — одна функция, принимающая JSON и возвращающая JSON.
    /// Здесь она обёрнута так, чтобы наружу торчали обычные ошибки Swift.
    @discardableResult
    private static func invoke(method: String, payload: [String: Any]) throws -> Any? {
        #if canImport(Libcore)
        let request: [String: Any] = [
            // Версию проверяет само ядро и отвергает чужую.
            //
            // Именно 1, а не 2. Двойка стоит в главной ветке libXray, но у нас
            // закреплён тег v1.260728.0, а он принимает только 0 или 1 и
            // отвечает «unsupported apiVersion». Число обязано соответствовать
            // версии из core/go.mod — меняются они вместе.
            "apiVersion": Self.apiVersion,
            "method": method,
            "payload": payload
        ]

        let data = try JSONSerialization.data(withJSONObject: request)
        let answer = LibXrayInvoke(String(decoding: data, as: UTF8.self))

        guard let raw = answer.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw Failure.rejected(tr("непонятный ответ ядра", "unreadable core answer"))
        }

        guard object["success"] as? Bool == true else {
            let message = object["error"] as? String ?? ""
            throw Failure.rejected(message.isEmpty
                                   ? tr("без объяснения", "no reason given")
                                   : message)
        }
        return object["data"]
        #else
        throw Failure.unavailable
        #endif
    }

    /// Превращает ссылку вида `vless://…` в набор outbound'ов Xray.
    ///
    /// Разбирает сам libXray, а не мы. Он знает все поля Xray, включая те, что
    /// есть только там — как раз xhttp с его mode, extra и прочим. Повторять
    /// этот разбор своими руками означало бы вечно догонять чужой формат.
    static func outbounds(fromShareLink link: String) throws -> [[String: Any]] {
        let data = try invoke(method: "convertShareLinksToXrayJson",
                              payload: ["text": link])

        guard let config = data as? [String: Any],
              let outbounds = config["outbounds"] as? [[String: Any]],
              !outbounds.isEmpty else {
            throw Failure.rejected(tr("в ссылке не нашлось сервера",
                                      "no server found in the link"))
        }
        return outbounds
    }

    /// Полный конфиг Xray: локальный SOCKS внутрь, сервер наружу.
    static func makeConfig(from link: String) throws -> String {
        let parsed = try outbounds(fromShareLink: link)

        // Берём только первый: ссылка описывает один сервер, а лишние выходы
        // с чужими тегами только мешали бы маршруту.
        var server = parsed[0]

        // Тег задаём свой: у ссылок он приходит произвольным, а маршрут ниже
        // ссылается на него по имени.
        server["tag"] = "proxy"

        // ОБЯЗАТЕЛЬНО убрать sendThrough.
        //
        // libXray прячет в это поле отображаемое имя сервера — у Xray просто
        // нет поля под название выхода. Само оно об этом знает и вычищает поле
        // перед своей проверкой, но в отданном нам конфиге оставляет. А для
        // Xray sendThrough — это локальный адрес, с которого выходить наружу,
        // и он честно пытался привязаться к «🇫🇷 France — быстрый»:
        // «unable to send through».
        server.removeValue(forKey: "sendThrough")

        // Выбрасываем все null.
        //
        // Это не косметика, без неё конфиг с Reality не собирается вовсе.
        // Структура REALITYConfig в Xray объявляет поля target и dest БЕЗ
        // omitempty, поэтому при переводе в JSON они выходят как null. А при
        // обратном чтении null — это уже не пустота: Xray видит заполненный
        // dest, решает, что перед ним конфиг СЕРВЕРА, и требует serverNames
        // с приватным ключом, которых у клиента нет и быть не может. Отсюда
        // «Failed to build REALITY config > empty serverNames».
        //
        // Чистим по всему дереву, а не только у Reality: поле без omitempty
        // здесь не единственное, и ловить их по одному — занятие без конца.
        // Для Xray отсутствующее поле и поле со значением null равнозначны
        // всюду, кроме этой самой проверки на присутствие.
        server = Self.strippingNulls(server)

        // Просим Xray разрешать адрес своего сервера ЧЕРЕЗ ВСТРОЕННЫЙ резолвер,
        // а не через системный. Только тогда он заглянет в dns.hosts ниже, куда
        // мы кладём уже готовый адрес. Без этой строки он идёт в систему —
        // то есть в туннель, которого без него ещё нет.
        var stream = server["streamSettings"] as? [String: Any] ?? [:]
        var sockopt = stream["sockopt"] as? [String: Any] ?? [:]
        sockopt["domainStrategy"] = "UseIP"
        stream["sockopt"] = sockopt
        server["streamSettings"] = stream

        // Готовый адрес сервера вместо имени.
        //
        // Xray разрешает имя своего сервера сам, через системный резолвер. А
        // системный резолвер после подъёма туннеля направлен внутрь туннеля —
        // то есть запрос идёт к sing-box, тот отдаёт его в SOCKS, а SOCKS
        // слушает тот самый Xray, который всё ещё ждёт ответа. Заклинивает
        // намертво, и снаружи это выглядит как «подключено, но ничего не
        // грузится» — без единой ошибки в журнале.
        //
        // Xray поднимается ПЕРВЫМ, до туннеля, поэтому здесь имя ещё
        // разрешается обычной сетью. Кладём результат в dns.hosts — дальше
        // Xray берёт адрес оттуда и наружу за ним не ходит. Так же поступают
        // OneXray и Happ.
        var dns: [String: Any] = ["servers": ["1.1.1.1", "8.8.8.8", "localhost"]]
        if let endpoint = try? SingBoxConfig.serverEndpoint(from: link) {
            let resolved = SingBoxConfig.resolve(endpoint.host)
            let addresses = resolved.v4 + resolved.v6
            // Для числового адреса запись бессмысленна, но и безвредна:
            // getaddrinfo вернёт его же.
            if !addresses.isEmpty {
                dns["hosts"] = [endpoint.host: addresses]
            }
        }

        let config: [String: Any] = [
            "dns": dns,

            // Как и у sing-box, уровень warning: на info ядро пишет каждое
            // соединение вместе с адресом назначения, то есть историю
            // посещений, и она осела бы в файле журнала.
            "log": ["loglevel": "warning"],

            "inbounds": [[
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "port": socksPort,
                "protocol": "socks",
                "settings": [
                    // Пароль не нужен: слушаем только петлю внутри своего же
                    // процесса, снаружи сюда не достучаться.
                    "auth": "noauth",
                    "udp": true
                ]
            ]],

            "outbounds": [server],

            "routing": ["rules": [[
                "type": "field",
                "inboundTag": ["socks-in"],
                "outboundTag": "proxy"
            ]]]
        ]

        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Рекурсивно убирает null из разобранного JSON.
    private static func strippingNulls(_ value: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, item) in value {
            if item is NSNull { continue }
            if let nested = item as? [String: Any] {
                result[key] = strippingNulls(nested)
            } else if let list = item as? [Any] {
                result[key] = list.compactMap { element -> Any? in
                    if element is NSNull { return nil }
                    if let nested = element as? [String: Any] { return strippingNulls(nested) }
                    return element
                }
            } else {
                result[key] = item
            }
        }
        return result
    }

    // MARK: - Управление ядром

    static func start(link: String) throws {
        let config = try makeConfig(from: link)

        // runXrayFromJson, а не runXray.
        //
        // runXray в этой версии принимает ПУТЬ К ФАЙЛУ, а не сам конфиг — то же
        // и у testXray. Значит, чтобы ими воспользоваться, конфиг пришлось бы
        // класть на диск, а в нём пароль и UUID сервера. Держать это в файле
        // ради проверки не стоит: ошибку конфигурации запуск возвращает и сам,
        // с тем же текстом от ядра.
        try invoke(method: "runXrayFromJson", payload: ["configJSON": config])
    }

    static func stop() {
        // При остановке разбираться уже не с чем: если ядро не запускалось,
        // ответ будет об ошибке, и это ровно то, что нам подходит.
        _ = try? invoke(method: "stopXray", payload: [:])
    }

    static var version: String {
        guard let data = try? invoke(method: "xrayVersion", payload: [:]),
              let object = data as? [String: Any],
              let version = object["version"] as? String else {
            return "—"
        }
        return version
    }
}
