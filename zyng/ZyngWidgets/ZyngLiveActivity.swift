import AppIntents
import NetworkExtension
import SwiftUI
import WidgetKit
import ActivityKit

/// Плашка соединения: на экране блокировки и в Dynamic Island.
struct ZyngLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TunnelActivityAttributes.self) { context in

            // --- Экран блокировки и баннер ---
            lockScreen(context.state)
                // Фон системный, без своей заливки.
                //
                // Раньше здесь стоял почти чёрный цвет, и на светлом экране
                // блокировки плашка выглядела чужеродным прямоугольником.
                // Системный фон подстраивается под обои и тему, а нужный
                // акцент даёт зелёная подложка внутри.
                .activitySystemActionForegroundColor(.green)

        } dynamicIsland: { context in

            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        shield
                        Text(context.state.flag)
                            .font(.system(size: 20))
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    // Системный таймер: отсчитывается сам, без обновлений
                    // активности каждую секунду.
                    Text(context.state.connectedAt, style: .timer)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: 70)
                        .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.serverName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Spacer()

                        if let ms = context.state.latency {
                            latencyBadge(ms)
                        }
                    }
                    .padding(.horizontal, 4)
                }

            } compactLeading: {
                shield
            } compactTrailing: {
                Text(context.state.connectedAt, style: .timer)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.green)
                    .frame(maxWidth: 44)
            } minimal: {
                shield
            }
            .keylineTint(.green)
        }
    }

    // MARK: - Экран блокировки

    private func lockScreen(_ state: TunnelActivityAttributes.ContentState) -> some View {
        VStack(spacing: 12) {

            // Верхняя карточка: флаг, состояние, сервер и кнопка отключения.
            HStack(spacing: 14) {

                // Флаг в скруглённом квадрате — как значок приложения. Один
                // эмодзи сам по себе на плашке смотрится случайным символом,
                // подложка делает из него опорную точку слева.
                Text(state.flag)
                    .font(.system(size: 30))
                    .frame(width: 52, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.thinMaterial)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                        Text(tr("Подключен", "Connected"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.green)
                    }

                    Text(state.serverName)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    if !state.detail.isEmpty {
                        Text(state.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                // Отключение прямо с экрана блокировки — ради этого плашка и
                // нужна: иначе, чтобы выключить туннель, приходится
                // разблокировать телефон и найти приложение.
                Button(intent: StopTunnelIntent()) {
                    Image(systemName: "power")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Color.green))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.green.opacity(0.16))
            )

            // Нижняя строка: сколько уже подключены и какая задержка.
            HStack {
                Text(state.connectedAt, style: .timer)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .frame(maxWidth: 110, alignment: .leading)

                Spacer()

                if let ms = state.latency {
                    latencyBadge(ms)
                } else {
                    Text(tr("Пинг", "Ping"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.thinMaterial))
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Мелочи

    private var shield: some View {
        Image(systemName: "bolt.shield.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.green)
    }

    private func latencyBadge(_ ms: Int) -> some View {
        let color: Color = ms < 100 ? .green : (ms < 250 ? .blue : .orange)
        return Text("\(ms) \(tr("мс", "ms"))")
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// Кнопка «выключить» на плашке.
///
/// Отдельно от ToggleTunnelIntent: тот требует iOS 18 (Пункт управления), а
/// плашка живёт с iOS 17, и общий тип потянул бы за собой ограничение версии.
struct StopTunnelIntent: AppIntent {

    static var title: LocalizedStringResource = "Отключить Zyng"
    static var description = IntentDescription("Выключает туннель Zyng")

    /// Всё делаем на месте, приложение открывать не нужно.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let manager = managers.first else { return .result() }

        // Правило «держать соединение» снимаем перед остановкой, иначе система
        // тут же поднимет туннель обратно и выключить его отсюда невозможно.
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            try await manager.saveToPreferences()
        }
        manager.connection.stopVPNTunnel()

        return .result()
    }
}

@main
struct ZyngWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ZyngLiveActivity()

        // Переключатель в Пункте управления появился только в iOS 18.
        if #available(iOS 18.0, *) {
            ZyngControl()
        }
    }
}
