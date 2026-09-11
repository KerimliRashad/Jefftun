import Foundation

/// Язык интерфейса.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case ru
    case en

    var id: String { rawValue }

    /// Название пишем на самом языке — так его узнают, даже если сейчас включён
    /// другой. Исключение — «как в системе»: его читают на текущем.
    var title: String {
        switch self {
        case .system: return tr("Как в системе", "System")
        case .ru:     return "Русский"
        case .en:     return "English"
        }
    }

    var flag: String {
        switch self {
        case .system: return "🌐"
        case .ru:     return "🇷🇺"
        case .en:     return "🇬🇧"
        }
    }

    /// Русский показываем только там, где он действительно язык системы.
    var isRussian: Bool {
        switch self {
        case .ru: return true
        case .en: return false
        case .system:
            let code = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"
            return code == "ru"
        }
    }
}

/// Текущий язык для функции `tr`.
///
/// Отдельная переменная, а не обращение к `AppSettings`: строки нужны и в
/// местах вне главного актора, а гонок здесь нет — значение меняется только
/// при переключении в настройках.
enum L10n {
    nonisolated(unsafe) static var language: AppLanguage = .system
    static var isRussian: Bool { language.isRussian }
}

/// Строка на текущем языке.
///
/// Оба варианта стоят рядом прямо в месте использования: видно, что именно
/// увидит пользователь, и нельзя забыть перевод — без второго аргумента код
/// просто не соберётся.
func tr(_ ru: String, _ en: String) -> String {
    L10n.isRussian ? ru : en
}
