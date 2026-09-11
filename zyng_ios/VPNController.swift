import NetworkExtension
import Foundation
import Combine

/// Управляет жизненным циклом VPN-туннеля Zyng.
///
/// Весь класс изолирован на main actor, а работа с NetworkExtension идёт через
/// async/await-варианты API. Благодаря этому `NETunnelProviderManager` (не Sendable)
/// никогда не пересекает границу изоляции — отсюда ноль ошибок строгой конкурентности
/// без обходных путей вроде `nonisolated(unsafe)`.
@MainActor
final class VPNController: NSObject, ObservableObject {

    static let shared = VPNController()

    /// Реальный статус туннеля, а не самодельный флаг: UI больше не рассинхронизируется
    /// с системой, если VPN отвалился сам.
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published var errorMessage: String?

    var isConnected: Bool { status == .connected }
    var isTransitioning: Bool {
        status == .connecting || status == .disconnecting || status == .reasserting
    }

    /// Должен точно совпадать с Bundle ID таргета расширения.
    private static let providerBundleIdentifier = "online.zyng.Zyng.ZyngTunnel"

    private var manager: NETunnelProviderManager?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange),
            name: .NEVPNStatusDidChange,
            object: nil
        )
        Task { await restoreExistingConfiguration() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Статус

    /// Уведомление приходит с произвольного потока, поэтому селектор nonisolated,
    /// а обновление состояния уходит на main actor.
    @objc private nonisolated func vpnStatusDidChange() {
        Task { @MainActor [weak self] in self?.syncStatus() }
    }

    private func syncStatus() {
        let newStatus = manager?.connection.status ?? .invalid
        guard newStatus != status else { return }
        status = newStatus
        NSLog("🔵 Zyng: VPN status = \(Self.name(for: newStatus))")
        if newStatus == .connected {
            errorMessage = nil
        }
    }

    private func restoreExistingConfiguration() async {
        do {
            manager = try await NETunnelProviderManager.loadAllFromPreferences().first
            syncStatus()
        } catch {
            // Раньше эта ошибка молча проглатывалась, и настоящая причина
            // ("permission denied") всплывала гораздо позже и в другом месте.
            NSLog("⚠️ Zyng: не удалось загрузить конфигурацию: \(error)")
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - Подключение

    func connect(key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Ключ пустой"
            return
        }

        errorMessage = nil

        do {
            // Переиспользуем существующую конфигурацию вместо удаления и создания
            // новой. Прошлый вариант вызывал removeFromPreferences() не дожидаясь
            // завершения и тут же сохранял новый профиль — гонка с системной базой
            // настроек, которая и выдавала NEVPNErrorConfigurationInvalid.
            let existing = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = existing.first ?? NETunnelProviderManager()

            let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol)
                ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleIdentifier
            proto.serverAddress = "Zyng"
            proto.providerConfiguration = ["key": trimmed]

            manager.protocolConfiguration = proto
            manager.localizedDescription = "Zyng VPN"
            manager.isEnabled = true
            manager.isOnDemandEnabled = false

            try await manager.saveToPreferences()
            // Сохранение помечает объект в памяти устаревшим: без повторной загрузки
            // startVPNTunnel() бросает NEVPNErrorConfigurationInvalid.
            try await manager.loadFromPreferences()

            self.manager = manager

            NSLog("🟡 Zyng: запускаю туннель…")
            try manager.connection.startVPNTunnel()
            // Успех здесь означает только «запрос принят». Реальное подключение
            // придёт через .NEVPNStatusDidChange, поэтому UI ведём от статуса.
            syncStatus()
        } catch {
            NSLog("❌ Zyng: подключение не удалось: \(error)")
            errorMessage = Self.describe(error)
            status = manager?.connection.status ?? .invalid
        }
    }

    func disconnect() {
        NSLog("🛑 Zyng: отключение")
        manager?.connection.stopVPNTunnel()
        syncStatus()
    }

    // MARK: - Диагностика

    private static func name(for status: NEVPNStatus) -> String {
        switch status {
        case .invalid:       return "invalid"
        case .disconnected:  return "disconnected"
        case .connecting:    return "connecting"
        case .connected:     return "connected"
        case .reasserting:   return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default:    return "unknown(\(status.rawValue))"
        }
    }

    /// Коды NEVPNErrorDomain почти всегда указывают на конкретную проблему
    /// конфигурации, а не на «что-то пошло не так».
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NEVPNErrorDomain,
              let code = NEVPNError.Code(rawValue: ns.code) else {
            return ns.localizedDescription
        }
        switch code {
        case .configurationInvalid:
            return "Конфигурация VPN недействительна. Проверь, что Bundle ID расширения — \(providerBundleIdentifier)."
        case .configurationDisabled:
            return "Конфигурация VPN отключена в Настройках → VPN."
        case .configurationStale:
            return "Конфигурация устарела, повтори попытку."
        case .configurationReadWriteFailed:
            return "Нет доступа к настройкам VPN. Проверь entitlements Personal VPN и Network Extension."
        case .connectionFailed:
            return "Не удалось установить соединение с сервером."
        case .configurationUnknown:
            return "Конфигурация VPN не найдена."
        @unknown default:
            return ns.localizedDescription
        }
    }
}
