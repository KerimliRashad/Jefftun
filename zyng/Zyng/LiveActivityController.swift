import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(ActivityKit)

/// Управляет плашкой на экране блокировки и в Dynamic Island.
///
/// Активность живёт ровно столько, сколько поднят туннель. Обновляем её редко —
/// таймер система отсчитывает сама по дате подключения, а не по нашим тикам.
@MainActor
final class LiveActivityController {

    static let shared = LiveActivityController()

    private var activity: Activity<TunnelActivityAttributes>?

    /// Последнее отправленное состояние.
    ///
    /// Обновить плашку просят из нескольких мест сразу: при переходе в
    /// «подключено», при возвращении приложения на экран и на каждый новый
    /// замер задержки. В момент подключения это совпадает, и система получала
    /// три одинаковых обновления подряд. Вреда от них нет, но запас обновлений
    /// у ActivityKit ограничен, и тратить его на повторы незачем.
    private var lastState: TunnelActivityAttributes.ContentState?

    private init() {}

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private var isForeground: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    func start(serverName: String, flag: String, connectedAt: Date,
               latency: Int?, detail: String = "") {
        guard AppSettings.shared.liveActivity, isSupported else { return }

        // Систему не обмануть: создать плашку можно только пока приложение на
        // экране. Туннель же часто поднимают из Пункта управления или по
        // правилу «держать соединение», когда приложение в фоне. Молча
        // пропускаем — плашка появится, когда приложение откроют.
        guard isForeground else { return }

        let state = TunnelActivityAttributes.ContentState(
            connectedAt: connectedAt,
            serverName: serverName,
            flag: flag,
            latency: latency,
            detail: detail
        )

        // После перезапуска приложения ссылка теряется, а плашка на экране
        // остаётся. Подхватываем её, иначе создадим вторую поверх первой.
        if activity == nil {
            activity = Activity<TunnelActivityAttributes>.activities.first
        }

        if activity != nil {
            update(state)
            return
        }

        do {
            activity = try Activity.request(
                attributes: TunnelActivityAttributes(),
                content: ActivityContent(state: state, staleDate: Self.staleDate())
            )
            lastState = state
        } catch {
            NSLog("⚠️ Zyng: не удалось запустить Live Activity: \(error.localizedDescription)")
        }
    }

    func update(serverName: String, flag: String, connectedAt: Date,
                latency: Int?, detail: String = "") {
        guard activity != nil else { return }
        update(TunnelActivityAttributes.ContentState(
            connectedAt: connectedAt,
            serverName: serverName,
            flag: flag,
            latency: latency,
            detail: detail
        ))
    }

    private func update(_ state: TunnelActivityAttributes.ContentState) {
        guard state != lastState else { return }
        lastState = state

        let current = activity
        Task {
            await current?.update(ActivityContent(state: state, staleDate: Self.staleDate()))
        }
    }

    /// Пока приложение спит, обновления не уходят, и показанная задержка
    /// стареет. Отметка позволяет системе притушить её вместо того, чтобы
    /// выдавать давнее значение за текущее. Само время идёт своим ходом —
    /// его система считает от даты подключения.
    private static func staleDate() -> Date {
        Date().addingTimeInterval(30 * 60)
    }

    func stop() {
        let current = activity
        activity = nil
        lastState = nil
        Task {
            await current?.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Убирает плашки, оставшиеся от прошлого запуска — например, если
    /// приложение выгрузили, не отключив туннель.
    func cleanupStale() {
        lastState = nil
        Task {
            for activity in Activity<TunnelActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
#endif
