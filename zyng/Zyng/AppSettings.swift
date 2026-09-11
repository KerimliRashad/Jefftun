import SwiftUI
import Combine

/// Настройки приложения. Хранятся в App Group, чтобы расширение тоже их видело:
/// часть из них уезжает в конфигурацию ядра.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // Тот же объект, что и у остальных: см. TunnelDiagnostics.shared —
    // повторное создание заставляло систему переоткрывать домен и ворчать
    // в лог на каждое обращение.
    private let defaults = TunnelDiagnostics.shared ?? .standard

    private enum Key {
        static let autoConnect = "settings_autoconnect"
        static let haptics = "settings_haptics"
        static let liveActivity = "settings_live_activity"
        static let verboseLog = "settings_verbose_log"
        static let theme = "settings_theme"
        static let language = "settings_language"
    }

    // MARK: - Оформление

    @Published var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Key.theme)
            ThemeState.isBlack = theme == .black
        }
    }

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            L10n.language = language
        }
    }

    /// Переподключаться автоматически, если соединение оборвалось.
    @Published var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: Key.autoConnect) }
    }

    @Published var haptics: Bool {
        didSet { defaults.set(haptics, forKey: Key.haptics) }
    }

    /// Плашка соединения на экране блокировки и в Dynamic Island.
    /// Подробный журнал ядра.
    ///
    /// По умолчанию выключен, и это принципиально: на подробном уровне ядро
    /// пишет каждое соединение вместе с адресом назначения — то есть историю
    /// посещений. Держать её на диске постоянно нельзя. Но когда туннель
    /// поднялся, а страницы не открываются, ядро молчит именно потому, что
    /// с его точки зрения всё хорошо, и без подробностей причину не увидеть.
    @Published var verboseLog: Bool {
        didSet { defaults.set(verboseLog, forKey: Key.verboseLog) }
    }

    @Published var liveActivity: Bool {
        didSet { defaults.set(liveActivity, forKey: Key.liveActivity) }
    }

    private init() {
        // Значения по умолчанию: у отсутствующего ключа bool читается как false,
        // поэтому для вибрации задаём true явно.
        autoConnect = defaults.bool(forKey: Key.autoConnect)
        haptics = defaults.object(forKey: Key.haptics) as? Bool ?? true
        liveActivity = defaults.object(forKey: Key.liveActivity) as? Bool ?? true
        verboseLog = defaults.object(forKey: Key.verboseLog) as? Bool ?? false

        let storedTheme = defaults.string(forKey: Key.theme) ?? AppTheme.dark.rawValue
        theme = AppTheme(rawValue: storedTheme) ?? .dark

        let storedLanguage = defaults.string(forKey: Key.language) ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: storedLanguage) ?? .system

        // didSet при инициализации не срабатывает, поэтому зеркала для тем и
        // языка нужно выставить вручную — иначе первый запуск будет с чужой
        // темой, а тексты на чужом языке.
        ThemeState.isBlack = theme == .black
        L10n.language = language
    }

    // MARK: - Версии

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
