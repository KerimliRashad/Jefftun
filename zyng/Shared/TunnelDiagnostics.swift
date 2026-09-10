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

    /// Куда ядро пишет СВОЙ журнал — тот, что задаётся полем log.output.
    ///
    /// Это и была причина вечного «Ядро ничего не записало». Мы перенаправляли
    /// stderr и надеялись поймать журнал там. Но sing-box внутри расширения в
    /// stderr не пишет: он отдаёт строки своей служебной части, а та рассылает
    /// их подключённым клиентам по служебному каналу. Приложение таким
    /// клиентом не было, и строки уходили в пустоту.
    ///
    /// Через stderr по-прежнему ловится паника Go — она случается мимо любого
    /// журнала, — а обычный вывод забираем отсюда.
    static var coreLogPath: String? {
        guard let container else { return nil }
        let dir = container.appendingPathComponent("core", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("core.log").path
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
        guard let path = tracePath else { return }
        let line = "\(timeFormatter.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        // Дописываем в файл, а не в общие настройки.
        //
        // Через настройки не работало: приложение и расширение — разные
        // процессы, и система отцепляет общий домен от службы настроек, о чём
        // и сообщает в консоли: «Using kCFPreferencesAnyUser with a container
        // is only allowed for System Containers, detaching from cfprefsd».
        // Я весь день считал эту строку безобидной. На деле она означала, что
        // записи расширения до приложения просто не доходят: дневник показывал
        // время прошлого запуска, а вывод ядра оставался пустым.
        //
        // Файл в общей папке такой болезни не подвержен.
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Очищает дневник. Зовётся в начале каждого запуска.
    static func clearTrace() {
        guard let path = tracePath else { return }
        try? FileManager.default.removeItem(atPath: path)
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    static func trace() -> String {
        guard let path = tracePath,
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return tr("Расширение ничего не записало.", "The extension wrote nothing.")
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)

        // Начало и конец, а не просто последние 200 строк.
        //
        // Ядро теперь пишет на уровне info, то есть много. Простой «хвост»
        // вымывал бы самое ценное — отметки запуска: каким ядром пошёл ключ,
        // какой адрес исключён из туннеля, когда он открылся. А без начала по
        // одному хвосту не понять, о каком вообще подключении речь.
        guard lines.count > 180 else { return lines.joined(separator: "\n") }

        let head = lines.prefix(30)
        let tail = lines.suffix(150)
        let skipped = lines.count - head.count - tail.count
        return (head
                + ["", "… пропущено строк: \(skipped) …", ""]
                + tail).joined(separator: "\n")
    }

    private static var tracePath: String? {
        guard let container else { return nil }
        let dir = container.appendingPathComponent("core", isDirectory: true)
        // Папку создаём здесь же.
        //
        // Первая запись в дневник делается раньше, чем расширение готовит
        // рабочие каталоги для ядра, — и без этой строки она молча пропадала
        // вместе со всеми следующими: писать было некуда.
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("trace.log").path
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
        for path in [stderrPath, coreLogPath].compactMap({ $0 }) {
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
        // Сначала собственный журнал ядра, затем stderr: там оседает паника Go,
        // которая случается мимо журнала.
        var lines: [String] = []
        for path in [coreLogPath, stderrPath].compactMap({ $0 }) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            lines += text.split(whereSeparator: \.isNewline).map(String.init)
        }
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
        var text = ""
        for path in [coreLogPath, stderrPath].compactMap({ $0 }) {
            text += (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        }
        guard !text.isEmpty else { return nil }

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
