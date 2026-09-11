import SwiftUI

/// Фирменный знак Zyng — угловатая «молния».
///
/// Рисуется фигурой, а не картинкой: масштабируется без потери чёткости на
/// любом размере и перекрашивается под состояние, не заводя отдельный ассет
/// под каждый цвет.
struct ZyngMark: Shape {

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height

        // Точки заданы долями стороны, поэтому знак одинаков на любом размере.
        let points = [
            CGPoint(x: rect.minX + w * 0.36, y: rect.minY + h * 0.20),
            CGPoint(x: rect.minX + w * 0.68, y: rect.minY + h * 0.42),
            CGPoint(x: rect.minX + w * 0.40, y: rect.minY + h * 0.57),
            CGPoint(x: rect.minX + w * 0.68, y: rect.minY + h * 0.80)
        ]

        var line = Path()
        line.move(to: points[0])
        for point in points.dropFirst() {
            line.addLine(to: point)
        }

        // Толщина тоже в долях: иначе на маленьком размере знак превращается
        // в кляксу, а на большом — в ниточку.
        return line.strokedPath(
            StrokeStyle(lineWidth: min(w, h) * 0.17, lineCap: .round, lineJoin: .round)
        )
    }
}

/// Знак в скруглённом квадрате — то, что стоит в шапке и на иконке.
struct ZyngLogo: View {

    var size: CGFloat = 34
    var background: LinearGradient = LinearGradient(
        colors: [JT.accent, Color(hex: "7A5CFF")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(background)

            ZyngMark()
                .fill(.white)
                .frame(width: size * 0.86, height: size * 0.86)
        }
        .frame(width: size, height: size)
    }
}


// MARK: - Логотип словом

/// Буква Z, у которой средняя диагональ — молния.
///
/// Это и есть весь замысел логотипа: знак и первая буква названия — одно и то
/// же. Отдельная иконка-молния рядом со словом «Zyng» дублировала смысл дважды,
/// а так название само себя и объясняет.
///
/// Рисуется одной ломаной с круглыми стыками: верхняя перекладина, диагональ с
/// изломом посередине, нижняя перекладина. Излом небольшой — если сделать его
/// заметнее, буква перестаёт читаться как Z и превращается в значок.
struct ZyngZ: Shape {

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + w * x, y: rect.minY + h * y)
        }

        var line = Path()
        line.move(to: point(0.10, 0.12))          // начало верхней перекладины
        line.addLine(to: point(0.90, 0.12))       // верхняя перекладина
        line.addLine(to: point(0.38, 0.46))       // диагональ вниз
        line.addLine(to: point(0.62, 0.56))       // излом — та самая молния
        line.addLine(to: point(0.10, 0.88))       // диагональ до низа
        line.addLine(to: point(0.90, 0.88))       // нижняя перекладина

        // Толщина в долях высоты: на любом размере буква одинаковой плотности.
        //
        // Значение подобрано по иконке, где то же слово набрано настоящим
        // шрифтом: штрих Z должен читаться одним весом с соседними буквами,
        // иначе он выглядит либо приклеенным значком, либо тонкой ниточкой.
        return line.strokedPath(
            StrokeStyle(lineWidth: h * 0.175, lineCap: .round, lineJoin: .round)
        )
    }
}

/// Логотип — всё слово целиком.
///
/// Первая буква рисуется фигурой, остальные — шрифтом. Смешивать так можно
/// потому, что подобран один ритм: толщина штриха Z повторяет плотность
/// начертания black, а высота выставлена по высоте прописных, а не по кеглю —
/// иначе буква стояла бы выше соседок на треть.
///
/// Цвет — общий градиент на всё слово, а не на каждую букву отдельно: переход
/// идёт слева направо через всю надпись, и она читается как единое целое.
struct ZyngWordmark: View {

    /// Высота прописных букв. От неё считается всё остальное.
    var capHeight: CGFloat = 22

    /// Тень-свечение под словом. На тёмном фоне добавляет глубины, на светлом
    /// выглядит грязью — поэтому включается отдельно.
    var glowing: Bool = true

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [JT.accent, Color(hex: "7A5CFF"), Color(hex: "B07CFF")],
            startPoint: .leading, endPoint: .trailing
        )
    }

    var body: some View {
        // Кегль выводим из высоты прописных: у системного шрифта она примерно
        // 0.72 кегля. Без этого пересчёта Z и «yng» разъезжаются по высоте.
        let fontSize = capHeight / 0.72

        HStack(alignment: .firstTextBaseline, spacing: capHeight * 0.12) {
            ZyngZ()
                .frame(width: capHeight * 0.82, height: capHeight)
                // Выравниваем по базовой линии текста: фигура о шрифте ничего
                // не знает, и без сдвига она «висела» бы над строкой.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }

            Text("yng")
                // Обычное начертание, не скруглённое.
                //
                // Скруглённое смотрелось мягче, но рядом с угловатой Z читалось
                // как другой шрифт: у неё прямые штрихи и острые сломы. Здесь
                // важнее единство, а не мягкость по отдельности.
                .font(.system(size: fontSize, weight: .heavy))
                // Плотнее обычного: у black начертания просветы между буквами
                // широкие, и слово распадалось на отдельные знаки.
                .tracking(-fontSize * 0.02)
        }
        .foregroundStyle(gradient)
        .shadow(color: glowing ? JT.accent.opacity(0.35) : .clear,
                radius: capHeight * 0.5, y: capHeight * 0.1)
    }
}
