import Foundation
import Libcore

/// Забирает у ядра скорость и объём трафика и кладёт их в общую папку.
///
/// Почему через клиента, а не напрямую. Ядро считает трафик само, но наружу
/// отдаёт его только одним способом: тому, кто подключился к его служебному
/// каналу и попросил присылать состояние. Обработчик сервера, который у нас
/// уже есть, этих сообщений не получает — он про другое.
///
/// Поэтому расширение подключается к собственному же серверу как обычный
/// клиент. Выглядит окольно, но это и есть предусмотренный путь: так устроены
/// все клиенты sing-box, просто у них сервер в другом процессе.
///
/// Если что-то не сложилось — молчим. Показ трафика приятен, но туннель важнее:
/// ни одна ошибка отсюда не должна мешать соединению.
final class TrafficReporter: NSObject, LibboxCommandClientHandlerProtocol {

    private var client: LibboxCommandClient?

    /// Накопленные значения на случай, если ядро пришлёт только скорость.
    private var lastUp: Int64 = 0
    private var lastDown: Int64 = 0

    func start() {
        let options = LibboxCommandClientOptions()
        // Команды добавляются методом, а не присваиванием: в ядре их список,
        // и клиент вправе подписаться сразу на несколько. Нам нужна одна.
        options.addCommand(Int32(LibboxCommandStatus))
        // Раз в секунду: чаще незачем — цифры на экране всё равно меняются
        // не быстрее, а каждое сообщение будит процесс расширения.
        options.statusInterval = Int64(NSEC_PER_SEC)

        guard let client = LibboxNewCommandClient(self, options) else { return }
        self.client = client

        // Ядро поднимает служебный канал не мгновенно, поэтому пробуем
        // несколько раз и не шумим, если не вышло.
        Task.detached { [weak self] in
            for _ in 0..<10 {
                if (try? client.connect()) != nil { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                if self == nil { return }
            }
            NSLog("⚠️ Zyng: статистика трафика недоступна")
        }
    }

    func stop() {
        try? client?.disconnect()
        client = nil
        TrafficStats.clear()
    }

    // MARK: - Сообщения ядра

    func writeStatus(_ message: LibboxStatusMessage?) {
        guard let message else { return }

        // Итоги ядро обнуляет при перезапуске сервиса, поэтому запоминаем
        // последнее ненулевое: иначе счётчик на экране прыгал бы к нулю при
        // каждой пересборке маршрутов.
        if message.uplinkTotal > 0 { lastUp = message.uplinkTotal }
        if message.downlinkTotal > 0 { lastDown = message.downlinkTotal }

        TrafficStats(
            upSpeed: message.uplink,
            downSpeed: message.downlink,
            upTotal: lastUp,
            downTotal: lastDown,
            at: Date()
        ).save()
    }

    // MARK: - Остальное из договора
    //
    // Клиент обязан реализовать весь набор, хотя подписан только на состояние.
    // Пустые тела здесь — не небрежность: этих сообщений мы не просили.

    func connected() {}
    func disconnected(_ message: String?) {}
    func clearLogs() {}
    func writeLogs(_ messageList: LibboxLogIteratorProtocol?) {}
    func setDefaultLogLevel(_ level: Int32) {}
    func writeGroups(_ message: LibboxOutboundGroupIteratorProtocol?) {}
    func initializeClashMode(_ modeList: LibboxStringIteratorProtocol?, currentMode: String?) {}
    func updateClashMode(_ newMode: String?) {}
    // Имя без «ConnectionEvents» — так его назвал gomobile при переводе
    // интерфейса Go в Objective-C. Компилятор на это прямо и указывает.
    func write(_ events: LibboxConnectionEvents?) {}
}
