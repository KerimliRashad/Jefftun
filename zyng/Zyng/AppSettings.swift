import SwiftUI
import Combine

/// Настройки приложения. Хранятся в App Group, чтобы расширение тоже их видело —
/// выбор DNS влияет на конфигурацию ядра.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // Тот же объект, что и у остальных: см. TunnelDiagnostics.shared —
    // повторное создание заставляло систему переоткрывать домен и ворчать
    // в лог на каждое обращение.
    private let defaults = TunnelDiagnostics.shared ?? .standard

    private enum Key {
        static let dns = "settings_dns"
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

    // MARK: - DNS

    enum DNSProvider: String, CaseIterable, Identifiable {
        case cloudflare
        case google
        case adguard
        case quad9

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cloudflare: return "Cloudflare"
            case .google:     return "Google"
            case .adguard:    return "AdGuard"
            case .quad9:      return "Quad9"
            }
        }

        var subtitle: String {
            switch self {
            case .cloudflare:
                return tr("1.1.1.1 · быстрый, но блокируется у части провайдеров",
                          "1.1.1.1 · fast, but blocked by some ISPs")
            case .google:
                return tr("8.8.8.8 · надёжный, работает почти везде",
                          "8.8.8.8 · reliable, works almost everywhere")
            case .adguard:
                return tr("94.140.14.14 · режет рекламу",
                          "94.140.14.14 · blocks ads")
            case .quad9:
                return tr("9.9.9.9 · блокирует вредоносное",
                          "9.9.9.9 · blocks malware")
            }
        }

        /// Адрес, который уйдёт в конфигурацию ядра.
        var address: String {
            switch self {
            case .cloudflare: return "1.1.1.1"
            case .google:     return "8.8.8.8"
            case .adguard:    return "94.140.14.14"
            case .quad9:      return "9.9.9.9"
            }
        }

        var icon: String {
            switch self {
            case .cloudflare: return "bolt.fill"
            case .google:     return "checkmark.shield.fill"
            case .adguard:    return "hand.raised.fill"
            case .quad9:      return "lock.shield.fill"
            }
        }
    }

    @Published var dns: DNSProvider {
        didSet { defaults.set(dns.rawValue, forKey: Key.dns) }
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
        // По умолчанию Google: Cloudflare у ряда провайдеров недоступен, и тогда
        // резолвинг встаёт целиком — соединение есть, а сайты не открываются.
        let stored = defaults.string(forKey: Key.dns) ?? DNSProvider.google.rawValue
        dns = DNSProvider(rawValue: stored) ?? .google

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
