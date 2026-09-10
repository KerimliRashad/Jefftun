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

    /// Момент установления соединения — берём у системы, а не считаем сами.
    /// Своё значение терялось при выгрузке экрана, и таймер после сворачивания
    /// начинался заново. Система же помнит его, пока туннель жив.
    @Published private(set) var connectedDate: Date?

    var isConnected: Bool { status == .connected }
    var isTransitioning: Bool {
        status == .connecting || status == .disconnecting || status == .reasserting
    }

    /// Должен точно совпадать с Bundle ID таргета расширения.
    private static let providerBundleIdentifier = "online.zyng.Zyng.ZyngTunnel"

    private var manager: NETunnelProviderManager?

    /// Идёт ли попытка подключения и удалась ли она. По одному лишь предыдущему
    /// статусу судить нельзя: путь бывает и connecting → disconnected, и
    /// connecting → disconnecting → disconnected.
    private var isAttempting = false
    private var reachedConnected = false

    /// Номер попытки. Причину сбоя приходится ждать пару секунд, и за это время
    /// пользователь успевает нажать «подключить» снова. Без номера сообщение от
    /// прошлой, неудачной попытки всплывало бы поверх уже работающего туннеля.
    private var attempt = 0

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
        connectedDate = manager?.connection.connectedDate
        NSLog("🔵 Zyng: VPN status = \(Self.name(for: newStatus))")

        switch newStatus {
        case .connected:
            reachedConnected = true
            isAttempting = false
            errorMessage = nil
            dumpDiary()

        case .disconnected:
            // Туннель отвалился, так и не подключившись. Своей ошибки система
            // здесь не даёт, поэтому забираем причину у расширения.
            if isAttempting && !reachedConnected {
                isAttempting = false
                reportFailure(for: attempt)
            }
            isAttempting = false

        default:
            break
        }
    }

    /// Печатает дневник расширения в консоль приложения.
    ///
    /// Расширение — отдельный процесс, и в консоль Xcode оно не пишет вовсе;
    /// его дневник лежит в общей папке и открывается вручную. На разборе
    /// неисправностей это стоило нам нескольких дней: присылали консоль
    /// приложения, а всё важное происходило там, куда никто не смотрел.
    ///
    /// Печатаем при КАЖДОМ подключении, а не только при неудаче: главные
    /// строки — какой ключ взят, какой адрес и протокол — нужны сразу, до
    /// того как что-то пойдёт не так.
    private func dumpDiary() {
        Task {
            // Ядро пишет с небольшой задержкой — даём ему договорить.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            NSLog("🟠 Zyng: ---- ход запуска туннеля ----\n%@", TunnelDiagnostics.trace())
        }
    }

    /// Ядро пишет причину в общий файл с небольшой задержкой, поэтому читаем
    /// не сразу и повторяем несколько раз.
    private func reportFailure(for attemptID: Int) {
        Task {
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 300_000_000)

                // Пока ждали, могла начаться новая попытка или туннель уже
                // поднялся — тогда старая причина никому не нужна.
                guard attemptID == attempt, !reachedConnected else { return }

                if let reason = TunnelDiagnostics.lastFailure(), !reason.isEmpty {
                    errorMessage = reason
                    return
                }
            }

            guard attemptID == attempt, !reachedConnected else { return }
            errorMessage = tr(
                "Туннель отключился, не подключившись, и расширение не оставило "
              + "причины. Скорее всего процесс не запустился — проверь подпись "
              + "расширения ZyngTunnel.",
                "The tunnel disconnected without ever connecting, and the extension "
              + "left no reason. Most likely its process never started — check the "
              + "signature of the ZyngTunnel extension.")
        }
    }

    /// Перечитывает состояние у системы. Нужно при возвращении из фона: пока
    /// приложение было свёрнуто, уведомления о смене статуса не приходили.
    func refresh() async {
        do {
            if manager == nil {
                manager = try await NETunnelProviderManager.loadAllFromPreferences().first
            }
            let current = manager?.connection.status ?? .invalid
            connectedDate = manager?.connection.connectedDate
            if current != status {
                syncStatus()
            }
        } catch {
            NSLog("⚠️ Zyng: не удалось обновить состояние: \(error)")
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

    /// Свежий объект настройки из системной базы.
    private static func currentManager() async throws -> NETunnelProviderManager {
        // Переиспользуем существующую вместо удаления и создания новой: прошлый
        // вариант вызывал removeFromPreferences() не дожидаясь завершения и тут
        // же сохранял новый профиль — гонка с системной базой настроек, которая
        // и выдавала NEVPNErrorConfigurationInvalid.
        try await NETunnelProviderManager.loadAllFromPreferences().first
            ?? NETunnelProviderManager()
    }

    /// Накладывает наши значения на объект настройки.
    ///
    /// Отдельно от сохранения намеренно: после перечитывания все поля
    /// возвращаются к тому, что лежит в системе, и наложить их нужно заново.
    private static func apply(key: String, to manager: NETunnelProviderManager) {
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = "Zyng"
        // Настройки уезжают вместе с ключом: расширение — отдельный процесс
        // и читать их из приложения напрямую не может.
        proto.providerConfiguration = [
            "key": key,
            "verbose": AppSettings.shared.verboseLog ? "1" : "0"
        ]

        manager.protocolConfiguration = proto
        manager.localizedDescription = "Zyng VPN"
        manager.isEnabled = true

        // Переподключение поручаем системе, а не приложению: расширение могут
        // выгрузить, сеть — переключиться с Wi-Fi на сотовую, сервер — оборвать
        // соединение. Приложение в этот момент обычно закрыто и сделать ничего
        // не может, а система поднимет туннель сама.
        manager.isOnDemandEnabled = AppSettings.shared.autoConnect
        manager.onDemandRules = [alwaysConnectRule()]
    }

    /// Та самая «configuration is stale». Приходит из двух разных доменов —
    /// NEVPNErrorDomain с кодом 4 и NEConfigurationErrorDomain с кодом 5.
    private static func isStale(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NEVPNErrorDomain,
           error.code == NEVPNError.configurationStale.rawValue { return true }
        return error.domain == "NEConfigurationErrorDomain" && error.code == 5
    }

    func connect(key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = tr("Ключ пустой", "The key is empty")
            return
        }

        // Одна попытка за раз.
        //
        // В журнале было три «запускаю туннель…» подряд: нажали несколько раз,
        // и каждый вызов сохранял свою копию настройки. Система такого не
        // прощает — после первого сохранения остальные объекты становятся
        // устаревшими, и все следующие попытки падают с «configuration is
        // stale», а туннель поднимается по СТАРОЙ настройке, то есть со старым
        // ключом. Именно это и выглядело как «поменял сервер, а он прежний».
        guard !isAttempting else { return }

        errorMessage = nil
        isAttempting = true
        reachedConnected = false
        attempt += 1

        do {
            // Переиспользуем существующую конфигурацию вместо удаления и создания
            // новой. Прошлый вариант вызывал removeFromPreferences() не дожидаясь
            // завершения и тут же сохранял новый профиль — гонка с системной базой
            // настроек, которая и выдавала NEVPNErrorConfigurationInvalid.
            var manager = try await Self.currentManager()

            // Настройку применяем и сохраняем с повторами.
            //
            // «configuration is stale» означает: объект в памяти описывает уже
            // не то, что лежит в системной базе, — её успел изменить кто-то
            // другой (прошлый вызов, расширение, сама система). Лечится это
            // только перечитыванием: берём свежий объект и накладываем свои
            // изменения заново. Настойчиво, но не бесконечно.
            var saved = false
            var lastError: Error?

            for attempt in 1...3 {
                Self.apply(key: trimmed, to: manager)
                do {
                    try await manager.saveToPreferences()
                    saved = true
                    break
                } catch {
                    lastError = error
                    guard Self.isStale(error), attempt < 3 else { break }
                    NSLog("🟡 Zyng: настройка устарела, перечитываю (попытка \(attempt))")
                    manager = try await Self.currentManager()
                }
            }

            guard saved else {
                throw lastError ?? NSError(domain: NEVPNErrorDomain,
                                           code: NEVPNError.configurationStale.rawValue)
            }

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
            // Обязательно снять: туннель даже не начал подниматься, а без
            // сброса защита от повторов заблокировала бы все следующие попытки
            // до перезапуска приложения.
            isAttempting = false
            errorMessage = Self.describe(error)
            status = manager?.connection.status ?? .invalid
        }
    }

    func disconnect() {
        NSLog("🛑 Zyng: отключение")
        isAttempting = false

        guard let manager else { return }

        // Правило подключения по требованию надо снять ДО остановки, иначе
        // система тут же поднимет туннель обратно и выключить его будет нельзя.
        if manager.isOnDemandEnabled {
            Task {
                manager.isOnDemandEnabled = false
                try? await manager.saveToPreferences()
                manager.connection.stopVPNTunnel()
                syncStatus()
            }
        } else {
            manager.connection.stopVPNTunnel()
            syncStatus()
        }
    }

    /// Держать туннель поднятым на любом интерфейсе.
    private static func alwaysConnectRule() -> NEOnDemandRule {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        return rule
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
            return tr("Конфигурация VPN недействительна. Проверь, что Bundle ID расширения — \(providerBundleIdentifier).",
                      "The VPN configuration is invalid. Check that the extension bundle ID is \(providerBundleIdentifier).")
        case .configurationDisabled:
            return tr("Конфигурация VPN отключена в Настройках → VPN.",
                      "The VPN configuration is disabled in Settings → VPN.")
        case .configurationStale:
            return tr("Конфигурация устарела, повтори попытку.",
                      "The configuration is stale, try again.")
        case .configurationReadWriteFailed:
            return tr("Нет доступа к настройкам VPN. Проверь entitlements Personal VPN и Network Extension.",
                      "No access to VPN settings. Check the Personal VPN and Network Extension entitlements.")
        case .connectionFailed:
            return tr("Не удалось установить соединение с сервером.",
                      "Could not establish a connection to the server.")
        case .configurationUnknown:
            return tr("Конфигурация VPN не найдена.", "The VPN configuration was not found.")
        @unknown default:
            return ns.localizedDescription
        }
    }
}
