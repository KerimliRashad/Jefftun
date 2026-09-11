import Foundation

/// Скорость и объём трафика — то, что ядро знает, а приложение показывает.
///
/// Через файл в общей папке, как и дневник.
///
/// Приложение не может спросить ядро напрямую: ядро живёт в расширении, это
/// отдельный процесс, и его библиотека слинкована только туда. Общие настройки
/// для такого обмена не годятся — система отцепляет их домен между процессами
/// (та самая строка про cfprefsd, из-за которой мы однажды сутки разбирали
/// пустой дневник). Файл такой болезни не подвержен.
struct TrafficStats: Codable, Equatable {

    /// Скорость прямо сейчас, байт в секунду.
    var upSpeed: Int64 = 0
    var downSpeed: Int64 = 0

    /// Сколько прошло за это подключение, байт.
    var upTotal: Int64 = 0
    var downTotal: Int64 = 0

    /// Когда значения записаны. По ним видно, живы ли они: расширение могли
    /// выгрузить, и тогда цифры застынут, а показывать их как текущие нельзя.
    var at: Date = .init()

    var isFresh: Bool { Date().timeIntervalSince(at) < 5 }

    static let empty = TrafficStats()

    // MARK: - Обмен

    private static var url: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: TunnelDiagnostics.appGroup
        ) else { return nil }

        let dir = container.appendingPathComponent("core", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("traffic.json")
    }

    /// Со стороны расширения.
    func save() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        // atomic: приложение читает этот файл раз в секунду, и без замены
        // целиком ему иногда доставался бы обрезанный кусок.
        try? data.write(to: url, options: .atomic)
    }

    /// Со стороны приложения.
    static func load() -> TrafficStats {
        guard let url, let data = try? Data(contentsOf: url),
              let stats = try? JSONDecoder().decode(TrafficStats.self, from: data) else {
            return .empty
        }
        return stats
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Человеческий вид объёма: 1.2 MB, 340 KB.
///
/// Свой, а не formatBytes из ServerStore: тот живёт в таргете приложения, а
/// этот файл общий — он компилируется ещё и в расширение, где ServerStore нет.
func formatTraffic(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var size = Double(bytes)
    var index = 0
    while size >= 1024, index < units.count - 1 {
        size /= 1024
        index += 1
    }
    return size >= 100 || index == 0
        ? String(format: "%.0f %@", size, units[index])
        : String(format: "%.1f %@", size, units[index])
}

/// Человеческий вид скорости: 1.2 MB/с, 340 KB/с.
func formatSpeed(_ bytesPerSecond: Int64) -> String {
    formatTraffic(bytesPerSecond) + tr("/с", "/s")
}
