import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Данные для Live Activity — плашки на экране блокировки и в Dynamic Island.
///
/// Живёт в Shared/, потому что описание должно быть одинаковым в приложении,
/// которое активность создаёт, и в виджете, который её рисует.
struct TunnelActivityAttributes: ActivityAttributes {

    /// Меняется по ходу соединения.
    struct ContentState: Codable, Hashable {
        /// Момент подключения. Система сама рисует по нему бегущий таймер —
        /// поэтому обновлять активность каждую секунду не нужно.
        var connectedAt: Date
        var serverName: String
        var flag: String
        /// Задержка в миллисекундах, если успели измерить.
        var latency: Int?
        /// Протокол и транспорт одной строкой — «VLESS · TCP · Reality».
        /// Опционально: активности, созданные прежней версией приложения, этого
        /// поля не содержат, и без значения по умолчанию они бы не прочитались.
        var detail: String = ""
    }

    /// Не меняется за время жизни активности.
    var appName: String = "Zyng"
}
#endif
