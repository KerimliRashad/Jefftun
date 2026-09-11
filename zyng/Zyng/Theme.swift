import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Тема оформления

enum AppTheme: String, CaseIterable, Identifiable {
    /// Как в системе: светло днём, тёмно ночью.
    case system
    case light
    case dark
    /// Чистый чёрный. На OLED-экранах пиксели фона выключены — заметно экономит
    /// батарею и выглядит глубже обычной тёмной темы.
    case black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return tr("Как в системе", "System")
        case .light:  return tr("Светлая", "Light")
        case .dark:   return tr("Тёмная", "Dark")
        case .black:  return tr("Чёрная", "Black")
        }
    }

    var subtitle: String {
        switch self {
        case .system: return tr("Следует настройке iPhone", "Follows your iPhone setting")
        case .light:  return tr("Всегда светлый фон", "Always a light background")
        case .dark:   return tr("Всегда тёмный фон", "Always a dark background")
        case .black:  return tr("Экономит батарею на OLED", "Saves battery on OLED")
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        case .black:  return "moonphase.new.moon"
        }
    }

    /// Чем накрыть корневой экран. nil — отдаём решение системе.
    var colorScheme: ColorScheme? {
        switch self {
        case .system:        return nil
        case .light:         return .light
        case .dark, .black:  return .dark
        }
    }
}

/// Флаг для динамических цветов.
///
/// Палитра собирается через `UIColor(dynamicProvider:)`, а провайдер вызывается
/// системой вне наших акторов — обращаться из него к `AppSettings` нельзя.
/// Поэтому нужное значение дублируется сюда обычной переменной.
enum ThemeState {
    nonisolated(unsafe) static var isBlack = false
}

// MARK: - Палитра

extension Color {
    init(hex: String) {
        let s = Scanner(string: hex); var v: UInt64 = 0; s.scanHexInt64(&v)
        self.init(red: Double((v>>16)&0xFF)/255,
                  green: Double((v>>8)&0xFF)/255,
                  blue: Double(v&0xFF)/255)
    }
}

/// Цвета приложения.
///
/// Все свойства вычисляемые, а не константы: при смене темы SwiftUI перерисует
/// экраны, свойства вызовутся заново и вернут цвета уже новой темы. С хранимыми
/// значениями переключение работало бы только после перезапуска.
enum JT {

    private static func tone(light: String, dark: String, black: String) -> Color {
        #if canImport(UIKit)
        let isBlack = ThemeState.isBlack
        return Color(UIColor { traits in
            if traits.userInterfaceStyle == .light {
                return UIColor(hexString: light)
            }
            return UIColor(hexString: isBlack ? black : dark)
        })
        #else
        return Color(hex: ThemeState.isBlack ? black : dark)
        #endif
    }

    /// Самый дальний слой — фон экрана.
    static var bg1: Color { tone(light: "F2F4F8", dark: "0E1014", black: "000000") }
    /// Фон строк и полей ввода.
    static var bg2: Color { tone(light: "FFFFFF", dark: "171A20", black: "0B0B0E") }
    /// Карточки поверх фона.
    static var card: Color { tone(light: "FFFFFF", dark: "1D2129", black: "121216") }
    /// Выделенная карточка.
    static var cardHi: Color { tone(light: "E9EEF7", dark: "272C36", black: "1C1C22") }
    static var stroke: Color { tone(light: "DCE2EC", dark: "2E343F", black: "26262E") }

    static var text: Color { tone(light: "111318", dark: "FFFFFF", black: "FFFFFF") }
    static var sub: Color { tone(light: "6B7484", dark: "8A94A6", black: "8A8A99") }

    // Акценты одинаковы во всех темах, только чуть темнее на светлом фоне,
    // иначе на белом они выцветают и текст по ним не читается.
    static var accent: Color { tone(light: "3F6FE8", dark: "5B8CFF", black: "5B8CFF") }
    static var green: Color { tone(light: "1FA76A", dark: "39D98A", black: "39D98A") }
    static var red: Color { tone(light: "D93B3B", dark: "FF5C5C", black: "FF5C5C") }

    /// Фон главного экрана. На чёрной теме градиента нет намеренно: любой
    /// перепад яркости на OLED съедает то, ради чего эту тему и включают.
    static var backdrop: LinearGradient {
        LinearGradient(colors: [bg1, ThemeState.isBlack ? bg1 : bg2],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Оформление карточек

/// Общий вид всех карточек приложения.
///
/// Раньше каждая карточка задавала фон и обводку сама, и они разъехались:
/// где-то радиус 14, где-то 18, обводка то есть, то нет. Здесь это собрано в
/// одно место — и заодно добавлено то, чего не хватало для глубины: блик по
/// верхней кромке и мягкая тень. Приём простой: свет падает сверху, поэтому
/// верхняя грань светлее нижней. Без него карточка выглядит плоской наклейкой.
struct JTCard: ViewModifier {
    var radius: CGFloat = 18
    var highlighted: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(highlighted ? JT.cardHi : JT.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [JT.text.opacity(0.10), JT.stroke.opacity(0.55)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            // Тень мягкая и почти незаметная: на тёмном фоне сильная тень
            // превращается в грязное пятно, а нужна только отделённость.
            .shadow(color: .black.opacity(ThemeState.isBlack ? 0.35 : 0.22),
                    radius: 14, x: 0, y: 6)
    }
}

extension View {
    func jtCard(radius: CGFloat = 18, highlighted: Bool = false) -> some View {
        modifier(JTCard(radius: radius, highlighted: highlighted))
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(hexString: String) {
        let s = Scanner(string: hexString); var v: UInt64 = 0; s.scanHexInt64(&v)
        self.init(red: CGFloat((v>>16)&0xFF)/255,
                  green: CGFloat((v>>8)&0xFF)/255,
                  blue: CGFloat(v&0xFF)/255,
                  alpha: 1)
    }
}
#endif
