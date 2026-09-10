import Foundation
import Combine

/// Замеряет задержку соединения, пока VPN подключён.
///
/// Меряем из приложения, а не из расширения: когда туннель поднят, трафик
/// приложения идёт через него, поэтому измеренное время — это реальная задержка
/// до сервера и обратно, ровно то, что интересует пользователя.
///
/// Настоящий ICMP-пинг на iOS без низкоуровневых сокетов недоступен, поэтому
/// используем HTTP-запрос к странице, которая отдаёт пустой ответ 204 —
/// у неё нет тела, и время измеряется почти чисто.
@MainActor
final class PingMonitor: ObservableObject {

    /// Задержка в миллисекундах. nil — ещё не измеряли или замер не удался.
    @Published private(set) var latency: Int?

    /// Замер не прошёл — сеть есть, но ответа нет.
    @Published private(set) var failed = false

    /// Почему не прошёл. Показывается рядом с «нет ответа».
    ///
    /// Без причины эта надпись бесполезна: она одинаково выглядит и когда
    /// туннель не пропускает трафик, и когда конкретный адрес недоступен, и
    /// когда сеть отвалилась совсем. А действия во всех трёх случаях разные.
    @Published private(set) var failureReason = ""

    private var task: Task<Void, Never>?

    /// Идёт ли замер прямо сейчас.
    ///
    /// `refreshNow` вызывается при возвращении из фона и мог совпасть с
    /// очередным тиком цикла: два замера шли одновременно и записывали
    /// результат наперегонки — показанное значение оказывалось от того, кто
    /// закончил последним, а не от того, кто начал позже.
    private var measuring = false

    /// Адреса, отдающие крошечный ответ. Пробуем по очереди: часть из них
    /// бывает недоступна у отдельных провайдеров или за конкретным сервером,
    /// и тогда замер врал бы «нет ответа» при работающем туннеле.
    private static let probeURLs = [
        // Проверка сети от Apple — доступна практически везде.
        URL(string: "https://captive.apple.com/hotspot-detect.html")!,
        URL(string: "https://www.gstatic.com/generate_204")!,
        URL(string: "https://cp.cloudflare.com/generate_204")!
    ]

    /// Адрес, ответивший последним, чтобы не перебирать список каждый раз.
    private var preferred: URL?

    /// Новая сессия на КАЖДЫЙ замер.
    ///
    /// Здесь раньше стояла одна сессия на всё время работы приложения, и рядом
    /// лежало объяснение, почему так нельзя: постоянная сессия переиспользует
    /// уже открытые соединения, а после поднятия туннеля они остаются на старом
    /// интерфейсе, и запросы уходят в никуда. Объяснение было верным, а код ему
    /// не соответствовал: ephemeral отключает кэш и куки, но переиспользование
    /// соединений — нет. Ровно это и происходило: туннель поднимался, и все три
    /// проверки подряд отваливались по таймауту при живом соединении.
    ///
    /// Сессия на один замер стоит недорого — замер и так уходит в сеть, — зато
    /// каждый раз начинается с чистого листа.
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.urlCache = nil
        // Соединение не переживает свой запрос — на всякий случай и явно.
        config.httpMaximumConnectionsPerHost = 1
        config.httpShouldUsePipelining = false
        return URLSession(configuration: config)
    }

    func start() {
        guard task == nil else { return }

        task = Task { [weak self] in
            // Полсекунды перед первым замером.
            //
            // Система сообщает «подключено», как только применены сетевые
            // настройки, но маршруты в этот момент ещё перестраиваются. Замер,
            // выпущенный в тот же миг, честно упирался в таймаут и показывал
            // «нет ответа» на исправном туннеле.
            try? await Task.sleep(nanoseconds: 500_000_000)

            // Дальше раз в 5 секунд.
            while !Task.isCancelled {
                await self?.measure()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        latency = nil
        failed = false
        failureReason = ""
    }

    /// Человеческая причина вместо системного текста вроде «-1001».
    private static func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "" }
        guard error.domain == NSURLErrorDomain else { return "" }
        switch error.code {
        case NSURLErrorTimedOut:
            return tr("сервер не отвечает", "the server is not responding")
        case NSURLErrorNetworkConnectionLost:
            return tr("соединение обрывается", "the connection keeps dropping")
        case NSURLErrorNotConnectedToInternet:
            return tr("нет сети", "no network")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return tr("имя не разрешается", "the name does not resolve")
        case NSURLErrorCannotConnectToHost:
            return tr("соединение отклонено", "connection refused")
        default:
            return ""
        }
    }

    /// Немедленный замер — например, при возвращении из фона, когда показанное
    /// значение успело устареть.
    func refreshNow() {
        Task { await measure() }
    }

    private func measure() async {
        guard !measuring else { return }
        measuring = true

        var lastError: Error?
        let session = Self.makeSession()
        defer {
            // Обязательно: иначе сессия и её соединения живут до сборки мусора,
            // а смысл именно в том, чтобы они не пережили этот замер.
            session.invalidateAndCancel()
            measuring = false
        }

        // Начинаем с того, который отвечал в прошлый раз.
        var candidates = Self.probeURLs
        if let preferred, let index = candidates.firstIndex(of: preferred) {
            candidates.remove(at: index)
            candidates.insert(preferred, at: 0)
        }

        for url in candidates {
            guard !Task.isCancelled else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            let started = Date()
            do {
                _ = try await session.data(for: request)
                guard !Task.isCancelled else { return }

                latency = Int(Date().timeIntervalSince(started) * 1000)
                failed = false
                failureReason = ""
                preferred = url
                return
            } catch {
                lastError = error
                continue
            }
        }

        guard !Task.isCancelled else { return }
        latency = nil
        failed = true
        failureReason = Self.describe(lastError)
    }
}
