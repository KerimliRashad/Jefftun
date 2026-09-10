import Foundation
import Network
import Combine

/// Пропускает только первый вызов. Нужен там, где несколько обработчиков могут
/// завершить одну и ту же операцию.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// Настройки замера.
///
/// Вынесены из класса намеренно. `LatencyProbe` помечен `@MainActor`, и всё
/// объявленное внутри — включая статические константы — наследует эту изоляцию.
/// Замер идёт вне главного актора, и каждое обращение к такой константе
/// компилятор считает выходом за пределы актора: в Swift 5 это предупреждение,
/// в Swift 6 уже ошибка. Здесь константы ничьи, и читать их можно откуда угодно.
private enum ProbeConfig {
    /// Трёх секунд хватало не всегда: на сотовой сети в это время попадает ещё
    /// и разрешение имени, и замер обрывался на полпути — рабочий сервер
    /// показывался мёртвым.
    static let timeout: TimeInterval = 4

    /// Одиночный отказ на мобильной сети — обычное дело, из-за него у части
    /// серверов вместо задержки оставался прочерк.
    static let attempts = 2

    /// Когда первый замер уложился в столько миллисекунд, второй не делаем.
    ///
    /// Повтор нужен ради двух вещей: пережить случайный отказ и не завысить
    /// цифру из-за разрешения имени в первом соединении. Быстрый ответ не
    /// страдает ни тем, ни другим — уточнять там нечего, а лишний заход стоит
    /// целого оборота до сервера. На хорошем списке это почти вдвое сокращает
    /// ожидание.
    static let goodEnough = 400

    /// Раньше было восемь. Замеры — это ожидание ответа, а не работа
    /// процессора: пока одно соединение молчит, остальные ничем не заняты.
    /// Шестнадцать одновременных заметно сокращают проход по длинному списку
    /// и при этом не начинают мешать друг другу на мобильной сети.
    static let parallel = 16

    /// Через сколько сдаёмся в любом случае. Страховка на случай, если
    /// системное соединение не позовёт ни один обработчик: крутилка в списке
    /// не должна жить вечно, что бы ни случилось ниже.
    static var deadline: TimeInterval { timeout * Double(attempts) + 3 }
}

/// Состояние замера одного сервера.
///
/// Раньше здесь был `Int??`, и «ещё не мерили» отличалось от «померяли, ответа
/// нет» только уровнем вложенности опционала — перепутать их было слишком
/// легко, а по такой ошибке строка списка крутилась без конца.
enum Latency: Equatable {
    case measuring
    case failed
    case ms(Int)

    var value: Int? {
        if case .ms(let v) = self { return v }
        return nil
    }
}

/// Измеряет задержку до серверов из списка, не поднимая туннель.
///
/// Меряется время установки TCP-соединения с адресом и портом сервера — это
/// честный отклик самого сервера. ICMP-пинг на iOS обычным приложениям
/// недоступен, а TCP-соединение показывает ровно то, что важно: ответит ли
/// сервер и как быстро.
@MainActor
final class LatencyProbe: ObservableObject {

    /// Один на всё приложение.
    ///
    /// Раньше список серверов держал свой экземпляр через @StateObject, а он
    /// живёт ровно столько, сколько открыт экран. Закрыл список, открыл снова —
    /// и весь список меряется заново с нуля, хотя цифры были получены секунду
    /// назад. Общий объект помнит их между открытиями, и главный экран может
    /// показать задержку выбранного сервера, не меряя её второй раз.
    static let shared = LatencyProbe()

    private init() {}

    @Published private(set) var results: [String: Latency] = [:]

    /// Идёт ли замер хоть чего-нибудь. Выводится из состояний, а не хранится
    /// отдельным флагом: отдельный флаг однажды уже застрял включённым.
    var isRunning: Bool { results.values.contains(.measuring) }

    /// `force` — мерить заново даже то, что уже измерено. Без него берётся
    /// только новое: автозамер при открытии списка и при смене вкладки не
    /// должен каждый раз гонять весь список по кругу.
    func measure(_ servers: [Server], force: Bool = false) async {
        let pending = servers.filter { server in
            guard let known = results[server.raw] else { return true }
            // Уже меряется в соседнем вызове — второй раз не берём.
            return known == .measuring ? false : force
        }
        guard !pending.isEmpty else { return }

        // Помечаем сразу все: пока идёт замер, строки показывают крутилку, а
        // параллельный вызов эти же серверы уже не возьмёт.
        for server in pending { results[server.raw] = .measuring }

        // Сторож. Если замер по любой причине не завершится, через deadline
        // крутилки всё равно погаснут и превратятся в «нет ответа».
        let watched = pending.map(\.raw)
        // Task внутри @MainActor-метода наследует главный актор, поэтому giveUp
        // зовётся уже на нём — await здесь был бы лишним, переключаться не на что.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ProbeConfig.deadline * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.giveUp(on: watched)
        }
        defer { watchdog.cancel() }

        await withTaskGroup(of: (String, Latency).self) { group in
            var index = 0

            func addNext() {
                guard index < pending.count else { return }
                let raw = pending[index].raw
                index += 1
                group.addTask { (raw, await probeServer(raw)) }
            }

            for _ in 0..<min(ProbeConfig.parallel, pending.count) { addNext() }

            for await (raw, latency) in group {
                results[raw] = latency
                addNext()
            }
        }
    }

    /// Сторож сработал — гасим всё, что так и осталось в замере.
    private func giveUp(on keys: [String]) {
        for key in keys where results[key] == .measuring {
            results[key] = .failed
        }
    }

    func latency(for server: Server) -> Latency? {
        results[server.raw]
    }

    func clear() {
        results = [:]
    }

    /// Отвечает ли сервер вообще. Один быстрый заход, без повторов.
    ///
    /// Нужен перед подключением. Само по себе поднятие туннеля почти всегда
    /// удаётся — это ведь местная операция, — и приложение показывает
    /// «Защищено» даже когда сервера на том конце нет. Человек видит зелёный
    /// статус, страницы не грузятся, и понять причину неоткуда. Поэтому
    /// спрашиваем сервер заранее и говорим прямо.
    nonisolated static func isReachable(_ raw: String) async -> Bool {
        await probeOnce(raw) != nil
    }
}

// MARK: - Замер одного сервера
//
// Свободные функции, а не методы класса: так они гарантированно вне главного
// актора и действительно выполняются параллельно. Пока это были статические
// методы @MainActor-класса, задачи из withTaskGroup выстраивались в очередь и
// шли по одной — обещанной параллельности не было вовсе.

/// Адрес и порт достаём тем же разборщиком, что строит конфиг ядра, — он уже
/// умеет все форматы, включая base64 внутри vmess.
private func probeEndpoint(_ raw: String) -> (String, UInt16)? {
    guard let server = try? SingBoxConfig.serverEndpoint(from: raw),
          server.port > 0, server.port <= 65535,
          !server.host.isEmpty else {
        return nil
    }
    return (server.host, UInt16(server.port))
}

private func probeServer(_ raw: String) async -> Latency {
    var best: Int?

    for attempt in 0..<ProbeConfig.attempts {
        if let ms = await probeOnce(raw) {
            // Быстрый ответ уточнять нечем — не тратим на него второй заход.
            if ms <= ProbeConfig.goodEnough {
                return .ms(min(best ?? ms, ms))
            }
            // Берём лучший результат, а не первый.
            //
            // Первое соединение с сервером включает разрешение имени и прогрев
            // маршрута, поэтому оно почти всегда медленнее последующих. Раньше
            // мы возвращали именно его, и цифра завышалась на сотню-другую
            // миллисекунд — сравнивать серверы между собой было бессмысленно.
            best = min(best ?? ms, ms)
        }
        if attempt + 1 < ProbeConfig.attempts {
            // Пауза перед повтором: подряд идущие попытки упираются в то же
            // состояние сети, что и первая. Ста миллисекунд для этого хватает,
            // а четверть секунды на каждый сервер складывалась в заметное
            // ожидание на длинном списке.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    return best.map(Latency.ms) ?? .failed
}

func probeOnce(_ raw: String) async -> Int? {
    guard let (host, port) = probeEndpoint(raw),
          let nwPort = NWEndpoint.Port(rawValue: port) else {
        return nil
    }

    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

    let parameters = NWParameters.tcp
    // Нас интересует отклик сервера, а не работа через уже поднятый туннель.
    parameters.preferNoProxies = true

    return await withCheckedContinuation { continuation in
        let connection = NWConnection(to: endpoint, using: parameters)
        let started = Date()

        // Продолжение можно возобновить только один раз, а обработчик состояния
        // и таймаут могут сработать одновременно.
        let once = OnceFlag()

        // Зовётся и из обработчика соединения, и из таймаута — то есть с разных
        // потоков, поэтому @Sendable.
        @Sendable func finish(_ value: Int?) {
            guard once.claim() else { return }

            // ВАЖНО: обработчик снимаем до отмены соединения.
            //
            // Замыкание захватывает `connection`, а `connection` держит само
            // замыкание — получается цикл, и объект не освобождается никогда.
            // За каждым таким соединением остаётся жить наблюдатель за сетевым
            // путём, и при любой его смене — а поднятие туннеля это как раз
            // смена пути — все они разом сыпали в лог
            // «nw_path_necp_check_for_updates Failed to copy updated result».
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(returning: value)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(Int(Date().timeIntervalSince(started) * 1000))
            case .failed, .cancelled:
                finish(nil)
            case .waiting:
                // Сеть недоступна или имя не разрешается. Ждать полный таймаут
                // здесь бессмысленно — соединение само уже не поедет.
                finish(nil)
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))

        DispatchQueue.global().asyncAfter(deadline: .now() + ProbeConfig.timeout) {
            finish(nil)
        }
    }
}
