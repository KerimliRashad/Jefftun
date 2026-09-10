import Foundation

/// Общий канал диагностики между расширением и приложением.
///
/// Расширение — отдельный процесс, и его логи в консоли приложения не видны.
/// Хуже того, когда ядро падает, оно умирает мгновенно и не успевает ничего
/// сообщить через NetworkExtension: приложение видит только «отключено».
///
/// Поэтому вывод ядра перенаправляется в файл в App Group, а приложение читает
/// его и показывает причину прямо на экране.
enum TunnelDiagnostics {

    static let appGroup = "group.online.zyng.Zyng"

    /// Общие настройки группы. Один объект на процесс.
    ///
    /// Раньше он создавался заново на каждое обращение, и каждое такое
    /// создание заставляло систему заново открывать домен. Когда домен пуст,
    /// она на это ворчит в лог: «Couldn't read values in CFPrefsPlistSource…
    /// detaching from cfprefsd». Сообщение безвредное, но сыпалось оно
    /// постоянно и мешало читать всё остальное.
    static let shared: UserDefaults? = {
        let defaults = UserDefaults(suiteName: appGroup)
        // Домен не должен оставаться пустым: пустой — это отсутствующий файл,
        // а именно на него система и ворчит. clear() удаляет обе записи об
        // ошибке, и без этой отметки после первой же удачной попытки
        // подключения там снова не оставалось бы ничего.
        if defaults?.object(forKey: "schema") == nil {
            defaults?.set(1, forKey: "schema")
        }
        return defaults
    }()

    /// Куда ядро пишет свой вывод, включая панику Go.
    static var stderrPath: String? {
        container?.appendingPathComponent("core/stderr.log").path
    }

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    // MARK: - Дневник расширения

    /// Отметки о ходе запуска туннеля.
    ///
    /// Расширение — отдельный процесс, и его вывод в консоль Xcode не попадает:
    /// отладчик подключён к приложению. Весь день мы разбирали неполадку,
    /// видя только половину картины — сообщения приложения, — а самое
    /// интересное происходило там, куда мы не смотрели.
    ///
    /// Поэтому расширение отмечается здесь, в общей группе, а приложение эти
    /// отметки показывает. Адресов и ключей тут нет, только шаги.
    static func note(_ message: String) {
        guard let defaults = shared else { return }
        var lines = defaults.stringArray(forKey: "trace") ?? []
        let time = Self.timeFormatter.string(from: Date())
        lines.append("\(time)  \(message)")
        // Держим последние двести строк: сюда же попадает вывод самого ядра,
        // а он многословен. Расти без конца всё равно нельзя.
        defaults.set(Array(lines.suffix(200)), forKey: "trace")
    }

    /// Очищает дневник. Зовётся в начале каждого запуска.
    static func clearTrace() {
        shared?.removeObject(forKey: "trace")
    }

    static func trace() -> String {
        let lines = shared?.stringArray(forKey: "trace") ?? []
        return lines.isEmpty
            ? tr("Расширение ничего не записало.", "The extension wrote nothing.")
            : lines.joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Запись (со стороны расширения)

    /// Наши собственные ошибки — те, до которых ядро даже не дошло.
    static func record(_ message: String) {
        guard let defaults = shared else { return }
        defaults.set(message, forKey: "lastError")
        defaults.set(Date(), forKey: "lastErrorAt")
    }

    static func clear() {
        guard let defaults = shared else { return }
        defaults.removeObject(forKey: "lastError")
        defaults.removeObject(forKey: "lastErrorAt")

        // Старый вывод ядра тоже убираем, иначе после успешного запуска
        // покажется ошибка от прошлой попытки.
        if let path = stderrPath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Чтение (со стороны приложения)

    /// Весь вывод ядра целиком — для показа человеку.
    ///
    /// Причина сбоя (lastFailure) отвечает на вопрос «почему не подключилось».
    /// Но бывает хуже: туннель поднялся, а трафик не идёт — тогда ошибки нет
    /// вовсе, и подсказать нечем. Ядро в такие моменты обычно пишет что-то
    /// внятное про сервер или сертификат, просто это оседает в файле и никем
    /// не читается. Здесь мы его достаём.
    static func coreLog(limit: Int = 60) -> String {
        guard let path = stderrPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return tr("Ядро ничего не записало.", "The core wrote nothing.")
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else {
            return tr("Ядро ничего не записало.", "The core wrote nothing.")
        }
        return lines.suffix(limit).joined(separator: "\n")
    }

    /// Последняя причина сбоя: сначала наша ошибка, иначе — вывод ядра.
    static func lastFailure() -> String? {
        if let defaults = shared,
           let message = defaults.string(forKey: "lastError"),
           !message.isEmpty {
            return message
        }
        return coreOutputSummary()
    }

    /// Из вывода ядра берём самое информативное: строку паники, если она есть,
    /// иначе последние несколько строк.
    private static func coreOutputSummary(limit: Int = 6) -> String? {
        guard let path = stderrPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard !lines.isEmpty else { return nil }

        if let panic = lines.first(where: { $0.hasPrefix("panic:") }) {
            return panic
        }

        return lines.suffix(limit).joined(separator: "\n")
    }
}
