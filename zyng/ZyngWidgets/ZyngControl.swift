import AppIntents
import NetworkExtension
import SwiftUI
import WidgetKit

/// Переключатель Zyng в Пункте управления.
///
/// Требует iOS 18 — раньше сторонние элементы туда добавлять было нельзя.
/// На более старых версиях просто не появится, приложение это не ломает.
@available(iOS 18.0, *)
struct ZyngControl: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "online.zyng.Zyng.control",
            provider: StatusProvider()
        ) { isConnected in
            ControlWidgetToggle(
                "Zyng",
                isOn: isConnected,
                action: ToggleTunnelIntent()
            ) { connected in
                Label(
                    connected ? tr("Защищено", "Protected") : tr("Отключено", "Disconnected"),
                    systemImage: connected ? "bolt.shield.fill" : "bolt.shield"
                )
            }
            .tint(.green)
        }
        .displayName("Zyng VPN")
        .description("\(tr("Включить или выключить туннель", "Turn the tunnel on or off"))")
    }

    /// Состояние читаем прямо у системы, а не из своих настроек: туннель могли
    /// включить из приложения, из системных настроек или из этого же элемента.
    struct StatusProvider: ControlValueProvider {

        var previewValue: Bool { false }

        func currentValue() async throws -> Bool {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            return managers.first?.connection.status == .connected
        }
    }
}

/// Действие переключателя.
@available(iOS 18.0, *)
struct ToggleTunnelIntent: SetValueIntent {

    static var title: LocalizedStringResource = "Zyng VPN"
    static var description = IntentDescription("Включает и выключает туннель Zyng")

    @Parameter(title: "Включено")
    var value: Bool

    /// «Держать соединение» из настроек приложения.
    ///
    /// Виджет — отдельный процесс и до `AppSettings` не дотягивается, но сама
    /// настройка лежит в общей группе, так что читаем её оттуда напрямую.
    private var keepConnected: Bool {
        TunnelDiagnostics.shared?.bool(forKey: "settings_autoconnect") ?? false
    }

    func perform() async throws -> some IntentResult {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()

        guard let manager = managers.first else {
            // Профиля ещё нет — подключиться неоткуда, нужно сперва добавить
            // ключ в приложении.
            return .result()
        }

        if value {
            // Правило возвращаем на место.
            //
            // Выключение отсюда его снимает (иначе туннель нельзя погасить), но
            // раньше никто его не включал обратно: одно выключение из Пункта
            // управления — и «Держать соединение» оставалось выключенным
            // навсегда, хотя в настройках галочка стояла.
            if keepConnected && !manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            try manager.connection.startVPNTunnel()
        } else {
            // Правило «держать соединение» снимаем перед остановкой, иначе
            // система тут же поднимет туннель обратно и выключить его отсюда
            // будет невозможно.
            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                try await manager.saveToPreferences()
            }
            manager.connection.stopVPNTunnel()
        }

        // Состояние переключателя система сама не перечитывает — без этого он
        // остаётся в прежнем положении до следующего открытия Пункта управления.
        ControlCenter.shared.reloadControls(ofKind: "online.zyng.Zyng.control")

        return .result()
    }
}
