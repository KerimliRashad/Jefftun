import Foundation
import Combine

/// Подписка — ссылка, по которой провайдер отдаёт список серверов.
///
/// Имя, лимит трафика и срок действия приходят не в теле ответа, а в его
/// заголовках — так это устроено во всех панелях. Поэтому здесь хранится
/// не только список ключей.
struct Subscription: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    /// Имя из заголовка profile-title. Пока подписка не загружена — хост ссылки.
    var name: String
    var url: String
    var updatedAt: Date?
    /// Ключи в том виде, в каком пришли. Разбираются при чтении, чтобы
    /// сохранённые данные не зависели от версии парсера.
    var rawKeys: [String] = []
    /// Как часто обновлять, в часах. Панель может задать своё значение.
    var autoUpdateHours: Int = 3

    // Данные из заголовка subscription-userinfo.
    var uploaded: Int64 = 0
    var downloaded: Int64 = 0
    /// 0 означает безлимит.
    var totalTraffic: Int64 = 0
    var expiresAt: Date?

    /// Ссылка на личный кабинет, если панель её прислала.
    var webPage: String?

    var usedTraffic: Int64 { uploaded + downloaded }

    var isUnlimited: Bool { totalTraffic <= 0 }

    /// Доля израсходованного трафика, 0…1. Для безлимита не имеет смысла.
    var usedFraction: Double {
        guard !isUnlimited else { return 0 }
        return min(1, max(0, Double(usedTraffic) / Double(totalTraffic)))
    }

    var isStale: Bool {
        guard let updatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) > Double(autoUpdateHours) * 3600
    }
}

/// Человекочитаемый объём: 6 GB, 512 MB и так далее.
func formatBytes(_ value: Int64) -> String {
    guard value > 0 else { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var size = Double(value)
    var index = 0
    while size >= 1024, index < units.count - 1 {
        size /= 1024
        index += 1
    }
    return size >= 100 || index == 0
        ? String(format: "%.0f %@", size, units[index])
        : String(format: "%.1f %@", size, units[index])
}

/// Хранилище серверов: подписки и одиночные ключи.
@MainActor
final class ServerStore: ObservableObject {

    static let shared = ServerStore()

    @Published private(set) var subscriptions: [Subscription] = []
    /// Ключи, добавленные вручную, — отдельная вкладка.
    @Published private(set) var singleKeys: [String] = []

    /// Какой сервер выбран. Храним строкой ключа: id генерируется заново при
    /// каждом разборе, поэтому по нему выбор не пережил бы перезапуск.
    @Published private(set) var selectedRaw: String = ""

    @Published var refreshing: Set<UUID> = []
    @Published var lastError: String?

    private let defaults = UserDefaults.standard

    private enum Key {
        static let subscriptions = "zyng_subscriptions"
        static let singles = "zyng_keys"
        static let selected = "zyng_selected"
    }

    private init() {
        load()
    }

    // MARK: - Разобранные серверы

    /// Разобранные ключи. Ключ словаря — сама строка ключа.
    ///
    /// Раньше кэша не было, и каждое обращение к `allServers` или `selected`
    /// разбирало заново все ключи всех подписок: base64, JSON, URLComponents.
    /// Обращений много, а таймер на главном экране перерисовывается раз в
    /// секунду — разбор шёл по кругу и держал главный поток занятым.
    ///
    /// Вторая, менее очевидная беда: `Server.id` создаётся при разборе, поэтому
    /// у одного и того же сервера при каждом вызове был новый идентификатор.
    /// Для SwiftUI это означало, что все строки списка исчезли и появились
    /// заново, — он пересобирал их вместо того, чтобы обновить.
    ///
    /// Одна строка ключа всегда разбирается в одно и то же, так что кэш живёт
    /// до тех пор, пока ключ есть в списке.
    private var parsed: [String: Server] = [:]

    func server(for raw: String) -> Server? {
        if let cached = parsed[raw] { return cached }
        guard let server = parseServer(raw) else { return nil }
        parsed[raw] = server
        return server
    }

    /// Выбрасывает из кэша ключи, которых больше нет.
    private func pruneParsed() {
        var alive = Set(singleKeys)
        for subscription in subscriptions { alive.formUnion(subscription.rawKeys) }
        parsed = parsed.filter { alive.contains($0.key) }
    }

    var singleServers: [Server] {
        singleKeys.compactMap(server(for:))
    }

    func servers(in subscription: Subscription) -> [Server] {
        subscription.rawKeys.compactMap(server(for:))
    }

    /// Все серверы разом — из них выбирается активный.
    var allServers: [Server] {
        subscriptions.flatMap { servers(in: $0) } + singleServers
    }

    var selected: Server? {
        // Прямо из кэша по ключу, без сборки всего списка.
        //
        // Раньше здесь строился allServers — то есть склеивались массивы всех
        // подписок и одиночных ключей, — и только потом в нём искалась одна
        // строка. А `selected` читается на каждой перерисовке главного экрана,
        // включая ежесекундный тик таймера. Разбор был закэширован, но сборка
        // и склейка массивов повторялись всё равно.
        if !selectedRaw.isEmpty, let chosen = server(for: selectedRaw),
           containsKey(selectedRaw) {
            return chosen
        }
        // Запасной вариант выбираем среди рабочих: сервер с транспортом,
        // которого ядро не умеет, подключиться всё равно не даст.
        return allServers.first(where: \.isSupported) ?? allServers.first
    }

    func select(_ server: Server) {
        selectedRaw = server.raw
        defaults.set(selectedRaw, forKey: Key.selected)
    }

    // MARK: - Одиночные ключи

    /// Возвращает, сколько ключей добавилось: во вставленном тексте их может
    /// быть несколько строк.
    @discardableResult
    func addSingleKeys(from text: String) -> Int {
        let candidates = expand(text)
        let fresh = candidates.filter { key in
            !singleKeys.contains(key) && parseServer(key) != nil
        }
        guard !fresh.isEmpty else { return 0 }

        singleKeys.append(contentsOf: fresh)

        // Новый ключ сразу становится выбранным.
        //
        // Раньше выбор менялся, только если его вообще не было. Выглядело это
        // разумно — «не трогать чужой выбор», — а на деле означало вот что:
        // человек вставляет новый ключ, жмёт «подключить», и приложение
        // подключается СТАРЫМ. В журнале мы это и видели: вставлен vless на
        // 443, а в туннель уходит ss на 1234, потому что он остался выбранным.
        //
        // Ключ вставляют ровно затем, чтобы им пользоваться. Других причин нет.
        if let first = fresh.first {
            selectedRaw = first
            defaults.set(selectedRaw, forKey: Key.selected)
        }
        persist()
        return fresh.count
    }

    func removeSingleKey(_ raw: String) {
        singleKeys.removeAll { $0 == raw }
        fixSelectionIfNeeded()
        persist()
    }

    // MARK: - Подписки

    func addSubscription(url: String, name: String? = nil) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              parsed.scheme == "http" || parsed.scheme == "https" else {
            lastError = tr("Это не похоже на ссылку подписки", "That does not look like a subscription link")
            return
        }

        let sub = Subscription(
            name: name?.isEmpty == false ? name! : (parsed.host ?? tr("Подписка", "Subscription")),
            url: trimmed
        )

        subscriptions.append(sub)
        persist()

        await refresh(sub.id)

        // Если подписка не отдала ни одного сервера, оставлять её бессмысленно.
        guard let updated = subscriptions.first(where: { $0.id == sub.id }),
              !updated.rawKeys.isEmpty else {
            subscriptions.removeAll { $0.id == sub.id }
            persist()
            return
        }

        // Переключаемся на сервер новой подписки.
        //
        // По той же причине, что и с одиночным ключом: подписку добавляют,
        // чтобы ею пользоваться. Без этого человек добавлял новую, нажимал
        // «подключить» и попадал на прежний сервер из старой, уже мёртвой, —
        // и выглядело это как «приложение не работает».
        if let first = servers(in: updated).first(where: \.isSupported) {
            select(first)
        }
    }

    func removeSubscription(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        fixSelectionIfNeeded()
        persist()
    }

    func refresh(_ id: UUID) async {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }

        refreshing.insert(id)
        defer { refreshing.remove(id) }

        do {
            let profile = try await fetchProfile(from: subscriptions[index].url)
            guard !profile.keys.isEmpty else {
                lastError = tr("Подписка не вернула ни одного сервера",
                               "The subscription returned no servers")
                return
            }

            subscriptions[index].rawKeys = profile.keys
            subscriptions[index].updatedAt = Date()

            // Имя из панели важнее того, что подставили при добавлении.
            if let title = profile.title, !title.isEmpty {
                subscriptions[index].name = title
            }
            subscriptions[index].uploaded = profile.uploaded
            subscriptions[index].downloaded = profile.downloaded
            subscriptions[index].totalTraffic = profile.total
            subscriptions[index].expiresAt = profile.expiresAt
            subscriptions[index].webPage = profile.webPage
            if let hours = profile.updateHours {
                subscriptions[index].autoUpdateHours = hours
            }

            lastError = nil
            fixSelectionIfNeeded()
            persist()
        } catch {
            lastError = tr("Не удалось обновить: \(error.localizedDescription)",
                           "Could not refresh: \(error.localizedDescription)")
        }
    }

    /// Обновляет те подписки, у которых вышел срок. Вызывается при открытии.
    ///
    /// Параллельно, а не по очереди: раньше каждая подписка ждала предыдущую, и
    /// при нескольких недоступных панелях экран занимался работой на минуты —
    /// система считала это затянувшейся задачей запуска и грозилась выгрузить
    /// приложение.
    func refreshStale() async {
        let stale = subscriptions.filter(\.isStale).map(\.id)
        guard !stale.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for id in stale {
                group.addTask { await self.refresh(id) }
            }
        }
    }

    /// Обновляет все подписки, не глядя на срок.
    ///
    /// refreshStale обходит только просроченные — это правильно для фонового
    /// обновления. Но когда сервер молчит, а срок ещё не вышел, ждать его
    /// бессмысленно: список у нас на руках уже неверный.
    func refreshAll() async {
        let ids = subscriptions.map(\.id)
        guard !ids.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refresh(id) }
            }
        }
    }

    /// Панели часто отдают список только знакомым клиентам, поэтому
    /// представляемся по очереди разными и берём первый непустой ответ.
    ///
    /// Строки нарочно полные, с версиями. Раньше здесь стояли огрызки вроде
    /// «Happ/1.0» и «Streisand» — панели, которые сверяют User-Agent строго,
    /// таких клиентов не узнавали и отвечали 404, хотя подписка была живой.
    /// Версии здесь важны не меньше названий.
    ///
    /// Панели вроде Remnawave отдают РАЗНЫЙ список под разные клиенты и даже
    /// под разные их версии: новым клиентам — vless с Reality, старым —
    /// запасной набор попроще, обычно Shadowsocks. Мы представлялись
    /// «Happ/1.16.0», и панель честно выдавала нам legacy-список: шесть
    /// ss-серверов на node.kerimlicorp.com:1234, давно выключенных. Тот же
    /// адрес подписки в настоящем Happ отдавал vless на nodej…:443, который
    /// прекрасно работает.
    ///
    /// Со стороны это выглядело как «в Happ работает, в Zyng нет» — и мы
    /// несколько дней искали неисправность в ядре, которого она не касалась.
    private static let userAgents = [
        "Happ/2.9.1 (iPhone; iOS 18.5)",
        "v2rayNG/1.10.7",
        "Streisand/2.0.1",
        "Shadowrocket/2.2.65 CFNetwork/1568 Darwin/24.0.0",
        "SFI/1.12.11 (iOS)",
        "sing-box/1.13.0",
        "Zyng/1.0"
    ]

    /// Есть ли в ответе современные протоколы.
    ///
    /// Если хоть один User-Agent получил vless/vmess/trojan, а другой — только
    /// Shadowsocks, берём первый: это два разных набора от одной панели, и
    /// второй у таких провайдеров почти всегда устаревший.
    private static func hasModernKeys(_ keys: [String]) -> Bool {
        keys.contains { key in
            let scheme = key.prefix(while: { $0 != ":" }).lowercased()
            return ["vless", "vmess", "trojan", "hysteria2", "hy2", "tuic"].contains(String(scheme))
        }
    }

    /// Что удалось вытащить из ответа панели.
    private struct Profile {
        var keys: [String] = []
        var title: String?
        var uploaded: Int64 = 0
        var downloaded: Int64 = 0
        var total: Int64 = 0
        var expiresAt: Date?
        var updateHours: Int?
        var webPage: String?
    }

    /// Адреса, по которым панели отдают конфиг.
    ///
    /// Часть панелей на голый адрес подписки показывает HTML-страницу или
    /// отвечает 404, а конфиг лежит рядом — под суффиксом клиента или за
    /// параметром format. Единого стандарта нет, поэтому пробуем известные
    /// варианты. Ответ принимается только если в нём есть ключи, так что
    /// неудачная догадка ничего не портит.
    private static func urlVariants(of raw: String) -> [String] {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }

        var out = [base]
        for suffix in ["/v2ray", "/v2ray-json", "/sing-box", "/singbox", "/clash", "/clash-meta"] {
            out.append(base + suffix)
        }
        let separator = base.contains("?") ? "&" : "?"
        for format in ["v2ray", "v2ray-json", "sing-box", "clash"] {
            out.append("\(base)\(separator)format=\(format)")
        }
        return out
    }

    /// Ошибка про отсутствие связи, а не про поведение панели.
    /// Свой домен для уже опознанной сетевой ошибки: по нему внешний перебор
    /// понимает, что дело не в конкретном варианте адреса, и тоже прекращается.
    private static let networkDomain = "Zyng.network"

    private static func isNetworkDown(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == Self.networkDomain { return true }
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        // Таймаута здесь БОЛЬШЕ НЕТ, и это принципиально.
        //
        // Панели Remnawave собирают конфиг под клиента на лету и отвечают
        // небыстро — секунд по десять-пятнадцать. Мы ждали восемь, считали
        // таймаут за «сети нет» и после двух таких выдавали «адрес подписки
        // недоступен из этой сети». Подписка при этом была совершенно живой:
        // в Happ, который ждёт дольше, она открывалась.
        //
        // Медленный ответ и отсутствие сети — разные вещи. Первое лечится
        // терпением, второе — нет.
        case NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return true
        default:
            return false
        }
    }

    /// Системный текст вроде «The request timed out» ничего не подсказывает.
    /// Здесь как раз тот случай, когда причина почти всегда одна и та же.
    private static func networkError(_ underlying: Error) -> Error {
        let code = (underlying as NSError).code

        // Обрыв на середине — это не «нет сети».
        //
        // -1005 при живом интернете означает, что соединение с этим адресом
        // рвут: провайдер или оператор режет домен подписки. Такое лечится
        // ровно одним способом — идти к панели через туннель, и человеку
        // полезнее прочитать это, чем гадать, что у него со связью.
        let text: String = code == NSURLErrorNetworkConnectionLost
            ? tr("соединение с адресом подписки обрывают — похоже, его блокируют "
               + "в этой сети. Подключись к любому рабочему серверу: пока туннель "
               + "поднят, подписка обновится сама.",
                 "the connection to the subscription address keeps being cut — it "
               + "looks blocked on this network. Connect to any working server: "
               + "while the tunnel is up, the subscription refreshes itself.")
            : tr("адрес подписки недоступен из этой сети — "
               + "включи VPN на рабочем сервере и добавь её ещё раз",
                 "the subscription address is unreachable from this "
               + "network — connect to a working server and try again")

        return NSError(domain: Self.networkDomain, code: code,
                       userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// Сколько всего ждём подписку, сколько бы вариантов ни осталось.
    private static let fetchDeadline: TimeInterval = 60

    private func fetchProfile(from url: String) async throws -> Profile {
        let variants = Self.urlVariants(of: url)
        let started = Date()

        for (index, variant) in variants.enumerated() {
            // Общий срок важнее полноты перебора: вариантов адреса больше
            // десятка, и без него неудача растянулась бы на много минут.
            if Date().timeIntervalSince(started) > Self.fetchDeadline { break }

            // По исходному адресу перебираем все User-Agent, по запасным —
            // только первые три: иначе ожидание растянется на минуты.
            let agents = index == 0 ? Self.userAgents : Array(Self.userAgents.prefix(3))
            // Пустой профиль за успех не считаем: запасной адрес мог ответить
            // и не отдать ни одного ключа.
            do {
                let profile = try await fetchProfile(from: variant, agents: agents,
                                                     until: started.addingTimeInterval(Self.fetchDeadline))
                if !profile.keys.isEmpty { return profile }
            } catch {
                // Связи нет — остальные варианты адреса тоже не ответят.
                if Self.isNetworkDown(error) { throw error }
            }
        }

        // Ни один вариант не дал ключей — повторяем исходный запрос, чтобы
        // вернуть настоящую причину, а не молчаливый провал.
        return try await fetchProfile(from: url, agents: Self.userAgents,
                                      until: Date().addingTimeInterval(20))
    }

    private func fetchProfile(from url: String, agents: [String],
                              until deadline: Date) async throws -> Profile {
        guard let parsed = URL(string: url) else { return Profile() }

        var lastError: Error?
        /// Панель ответила успешно, но ключей не прислала.
        var answeredWithoutKeys = false
        /// Сколько попыток подряд упёрлись в саму сеть, а не в ответ панели.
        var networkFailures = 0
        /// Ответ со старым набором протоколов — на случай, если лучше не будет.
        var legacy: Profile?

        for agent in agents {
            // Срок общий на всю попытку — иначе семь имён клиентов по двадцать
            // секунд складываются в две минуты ожидания.
            if Date() > deadline { break }

            var request = URLRequest(url: parsed)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            // Двадцать секунд, а не восемь.
            //
            // Восьми «хватало живой панели с запасом» только в моём
            // представлении. Remnawave собирает конфиг под конкретного клиента
            // при каждом запросе и на медленной связи отвечает дольше. Чтобы
            // перебор при этом не растянулся на минуты, ниже стоит общий срок
            // на всю попытку.
            request.timeoutInterval = 20
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            // Без Accept часть панелей и защитных прослоек отбивает запрос,
            // хотя подписка живая. Настольный клиент его слал всегда.
            request.setValue("*/*", forHTTPHeaderField: "Accept")

            // Панели, которые считают устройства по подписке, ждут именно эти
            // заголовки — без них часть из них отдаёт пустой список.
            request.setValue(jtHWID(), forHTTPHeaderField: "x-hwid")
            request.setValue("ios", forHTTPHeaderField: "x-device-os")
            request.setValue(jtDeviceOS(), forHTTPHeaderField: "x-ver-os")
            request.setValue(jtDeviceModel(), forHTTPHeaderField: "x-device-model")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let type = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Content-Type") ?? "—"
                NSLog("🟣 Zyng подписка: %@ | %@ → %d, %d байт, %@",
                      parsed.absoluteString, agent, code, data.count, type)

                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    lastError = NSError(
                        domain: "Zyng", code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey:
                                    tr("сервер ответил \(http.statusCode)",
                                       "server replied \(http.statusCode)")]
                    )
                    continue
                }

                let body = String(decoding: data, as: UTF8.self)
                let keys = expand(body)
                let sample: String = keys.isEmpty
                    ? ", начало ответа: "
                        + String(body.prefix(160)).replacingOccurrences(of: "\n", with: " ")
                    : ", первый: " + String((keys.first ?? "").prefix(40))
                NSLog("🟣 Zyng подписка: ключей найдено %d%@", keys.count, sample)

                if keys.isEmpty {
                    // Ответ есть, ключей в нём нет — обычно это HTML-страница
                    // подписки: панель не узнала клиента и показала её вместо
                    // конфига. Запоминаем отдельно, иначе поверх ляжет код
                    // ошибки от следующего User-Agent и причина будет неверной.
                    answeredWithoutKeys = true
                    continue
                }

                var profile = Profile(keys: keys)
                if let http = response as? HTTPURLResponse {
                    Self.readHeaders(http, into: &profile)
                }

                // Современный набор забираем сразу. Устаревший запоминаем и
                // продолжаем перебор: вдруг под другим именем клиента панель
                // отдаст нормальный. Если не отдаст — вернём хотя бы этот.
                if Self.hasModernKeys(keys) { return profile }
                if legacy == nil { legacy = profile }
                continue
            } catch {
                NSLog("🟣 Zyng подписка: %@ | %@ → ошибка %@",
                      parsed.absoluteString, agent, (error as NSError).localizedDescription)

                // Сеть недоступна — перебирать дальше бессмысленно.
                //
                // Вариантов адреса и User-Agent в сумме больше сорока. Когда
                // связи нет вовсе (например, поднят туннель, через который
                // ничего не ходит), каждый из них честно ждёт свой таймаут, и
                // добавление подписки растягивается на минуты, заваливая лог
                // одинаковыми ошибками. Панель тут ни при чём — сдаёмся сразу
                // и показываем настоящую причину.
                if Self.isNetworkDown(error) {
                    networkFailures += 1
                    // Одной осечки мало: медленная панель тоже отвечает
                    // таймаутом, и сдаваться на ней сразу — терять живую
                    // подписку. Но и сорок попыток подряд не нужны.
                    if networkFailures >= 2 { throw Self.networkError(error) }
                }
                lastError = error
            }
        }

        // Успешный, но пустой ответ важнее кода ошибки от другого агента:
        // он означает, что панель жива и достижима, а проблема в другом.
        if answeredWithoutKeys {
            throw NSError(
                domain: "Zyng", code: 204,
                userInfo: [NSLocalizedDescriptionKey:
                            tr("панель ответила, но ключей не прислала — "
                             + "возможно, она не узнала приложение",
                               "the panel answered but sent no keys — "
                             + "it may not recognise this app")]
            )
        }
        // Ничего современного не нашлось — отдаём то, что есть.
        if let legacy { return legacy }
        if let lastError { throw lastError }
        return Profile()
    }

    /// Разбирает заголовки, которыми панели описывают подписку.
    private static func readHeaders(_ response: HTTPURLResponse, into profile: inout Profile) {
        func header(_ name: String) -> String? {
            let value = response.value(forHTTPHeaderField: name)?
                .trimmingCharacters(in: .whitespaces)
            return value?.isEmpty == false ? value : nil
        }

        // Имя профиля. Часто приходит закодированным: "base64:0JbQtdGE..."
        if let raw = header("profile-title") {
            profile.title = decodeTitle(raw)
        } else if let disposition = header("content-disposition"),
                  let range = disposition.range(of: "filename=") {
            profile.title = String(disposition[range.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }

        // subscription-userinfo: upload=1234; download=5678; total=0; expire=1700000000
        if let info = header("subscription-userinfo") {
            for pair in info.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)

                switch key {
                case "upload":   profile.uploaded = Int64(value) ?? 0
                case "download": profile.downloaded = Int64(value) ?? 0
                case "total":    profile.total = Int64(value) ?? 0
                case "expire":
                    if let seconds = Double(value), seconds > 0 {
                        profile.expiresAt = Date(timeIntervalSince1970: seconds)
                    }
                default: break
                }
            }
        }

        // Интервал панель задаёт в часах.
        if let interval = header("profile-update-interval"), let hours = Int(interval), hours > 0 {
            profile.updateHours = hours
        }

        profile.webPage = header("profile-web-page-url")
    }

    private static func decodeTitle(_ raw: String) -> String {
        let value = raw.hasPrefix("base64:")
            ? String(raw.dropFirst("base64:".count))
            : raw

        if let data = Data(base64Encoded: padBase64(value)),
           let decoded = String(data: data, encoding: .utf8),
           !decoded.isEmpty {
            return decoded
        }
        return raw
    }

    // MARK: - Разбор содержимого

    /// Превращает текст в список ключей. Подписки отдают либо готовые строки,
    /// либо всё это, закодированное в base64 одним куском.
    private func expand(_ text: String) -> [String] {
        let direct = lines(of: text)
        if !direct.isEmpty { return direct }

        // Готовый конфиг Xray или sing-box.
        //
        // Современным клиентам панель отдаёт именно его, а не список ссылок:
        // 22 КБ JSON с vless и Reality. Мы искали строки «vless://», не
        // находили ни одной и откатывались на запасной текстовый список —
        // шесть давно выключенных ss-серверов. Отсюда и «в Happ работает,
        // в Zyng нет». Разбор — в ConfigImport.
        let fromConfig = ConfigImport.keys(fromJSON: text)
        if !fromConfig.isEmpty { return fromConfig }

        if let data = Data(base64Encoded: padBase64(text)) {
            let decoded = String(decoding: data, as: UTF8.self)
            let fromBase64 = lines(of: decoded)
            if !fromBase64.isEmpty { return fromBase64 }

            let scanned = scatteredKeys(in: decoded)
            if !scanned.isEmpty { return scanned }
        }

        // Последняя попытка: ищем ключи по всему тексту.
        //
        // Выше строка засчитывается, только если начинается с протокола. Но
        // часть панелей вместо списка отдаёт свою HTML-страницу, а ключи лежат
        // внутри неё — в JavaScript, в JSON или в атрибуте кнопки «скопировать».
        // Тогда ни одна строка с протокола не начинается, и подписка выглядела
        // пустой при живом ответе.
        return scatteredKeys(in: text)
    }

    /// Ключи, разбросанные по тексту, а не стоящие по одному на строке.
    private func scatteredKeys(in text: String) -> [String] {
        // Перед ключом — начало, пробел, кавычка или скобка, но не буква и не
        // «/», иначе ss:// внутри обычной ссылки принимается за ключ.
        let pattern = #"(?<![A-Za-z0-9/:._-])"#
                    + #"(?:vless|vmess|trojan|ss|socks5?|hysteria2?|hy2|tuic)://"#
                    + #"[^\s"'<>\\\]\},]+"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        // Панели нередко отдают HTML, где амперсанды экранированы, — без этого
        // у ключа терялись бы все параметры после первого.
        let source = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")

        let full = NSRange(source.startIndex..<source.endIndex, in: source)
        var found: [String] = []

        for match in regex.matches(in: source, range: full) {
            guard let range = Range(match.range, in: source) else { continue }
            let key = String(source[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            if parseServer(key) != nil, !found.contains(key) {
                found.append(key)
            }
        }
        return found
    }

    private func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { parseServer($0) != nil }
    }

    // MARK: - Хранение

    /// Есть ли такой ключ в списках. Сравниваются строки, ничего не разбирается.
    private func containsKey(_ raw: String) -> Bool {
        if singleKeys.contains(raw) { return true }
        return subscriptions.contains { $0.rawKeys.contains(raw) }
    }

    private func fixSelectionIfNeeded() {
        // Сначала дешёвая проверка по строкам.
        //
        // Она выполняется при запуске приложения, а раньше начиналась с
        // построения allServers — то есть разбора КАЖДОГО ключа всех подписок
        // на главном потоке, ещё до появления первого кадра. При сотне серверов
        // это заметная задержка на ровном месте, хотя в подавляющем большинстве
        // случаев выбранный ключ на месте и делать нечего.
        if !selectedRaw.isEmpty, containsKey(selectedRaw) { return }

        let available = allServers
        guard selectedRaw.isEmpty || !available.contains(where: { $0.raw == selectedRaw }) else {
            return
        }

        // Предпочитаем рабочий сервер: иначе после обновления подписки выбор мог
        // упасть на первый попавшийся с неподдерживаемым транспортом.
        let fallback = available.first(where: \.isSupported) ?? available.first
        selectedRaw = fallback?.raw ?? ""
        defaults.set(selectedRaw, forKey: Key.selected)
    }

    /// Ключи и подписки — самое чувствительное, что есть в приложении: по ним
    /// можно подключиться к серверам пользователя. Поэтому они лежат не в
    /// обычных настройках, а в файле, который:
    ///
    /// * защищён до первой разблокировки устройства — с выключенного телефона
    ///   его не прочитать;
    /// * помечен как не подлежащий резервному копированию, иначе ключи уезжали
    ///   бы в iCloud, хотя политика обещает обратное.
    private struct Vault: Codable {
        var subscriptions: [Subscription] = []
        var singleKeys: [String] = []
    }

    private static var vaultURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: TunnelDiagnostics.appGroup)?
            .appendingPathComponent("servers.json")
    }

    private func persist() {
        pruneParsed()
        guard let url = Self.vaultURL else { return }

        let vault = Vault(subscriptions: subscriptions, singleKeys: singleKeys)
        guard let data = try? JSONEncoder().encode(vault) else { return }

        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try excludeFromBackup(url)
        } catch {
            NSLog("⚠️ Zyng: не удалось сохранить список серверов: \(error.localizedDescription)")
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func load() {
        if let url = Self.vaultURL,
           let data = try? Data(contentsOf: url),
           let vault = try? JSONDecoder().decode(Vault.self, from: data) {
            subscriptions = vault.subscriptions
            // Без проверки разбором: она заставляла разбирать все одиночные
            // ключи ещё до первого кадра, а нечитаемые и так отсеиваются при
            // построении singleServers.
            singleKeys = vault.singleKeys
        } else {
            migrateFromDefaults()
        }

        selectedRaw = defaults.string(forKey: Key.selected) ?? ""
        fixSelectionIfNeeded()
    }

    /// Прежние версии держали ключи в обычных настройках. Переносим их в файл
    /// и стираем оттуда — иначе копия так и осталась бы в резервных копиях.
    private func migrateFromDefaults() {
        if let data = defaults.data(forKey: Key.subscriptions),
           let decoded = try? JSONDecoder().decode([Subscription].self, from: data) {
            subscriptions = decoded
        }

        let raw = defaults.string(forKey: Key.singles) ?? ""
        singleKeys = raw.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { server(for: $0) != nil }

        guard !subscriptions.isEmpty || !singleKeys.isEmpty else { return }

        persist()
        defaults.removeObject(forKey: Key.subscriptions)
        defaults.removeObject(forKey: Key.singles)
        NSLog("🔒 Zyng: список серверов перенесён в защищённое хранилище")
    }
}
