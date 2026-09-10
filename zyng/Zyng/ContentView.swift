import SwiftUI
import Combine
import NetworkExtension
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Кросс-платформенные помощники (iOS + macOS)

func jtClipboard() -> String? {
    #if canImport(UIKit)
    return UIPasteboard.general.string
    #elseif canImport(AppKit)
    return NSPasteboard.general.string(forType: .string)
    #else
    return nil
    #endif
}

func jtHaptic() {
    #if canImport(UIKit)
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    #endif
}

func jtDeviceOS() -> String {
    #if canImport(UIKit)
    return UIDevice.current.systemVersion
    #else
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    #endif
}

func jtDeviceModel() -> String {
    #if canImport(UIKit)
    return UIDevice.current.model
    #else
    return "Mac"
    #endif
}

func jtHWID() -> String {
    #if canImport(UIKit)
    return UIDevice.current.identifierForVendor?.uuidString ?? "zyng-ios"
    #else
    return "zyng-mac"
    #endif
}

extension View {
    @ViewBuilder func jtNoAutocap() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}

// MARK: - Модель

struct Server: Identifiable, Equatable {
    let id = UUID()
    let raw: String
    let name: String
    let proto: String
    /// Транспорт из ключа: TCP, WS, gRPC, XHTTP и так далее.
    let transport: String
    /// Умеет ли ядро такой транспорт. Неподдерживаемые показываем в списке
    /// помеченными, чтобы это не выяснялось после неудачного подключения.
    let isSupported: Bool
    /// Протокол работает поверх UDP (Hysteria2, TUIC). Проверить такой сервер
    /// TCP-соединением нельзя: порт закрыт для TCP, и замер выглядел бы как
    /// «сервер не отвечает», хотя он полностью рабочий.
    let usesDatagrams: Bool
    let flag: String
}

func flagFor(_ name: String) -> String {
    let n = name.lowercased()
    let map: [(String,String)] = [
        ("москва","🇷🇺"),("россия","🇷🇺"),("russia","🇷🇺"),("спб","🇷🇺"),("moscow","🇷🇺"),
        ("герман","🇩🇪"),("german","🇩🇪"),("франкфурт","🇩🇪"),("frankfurt","🇩🇪"),
        ("нидерл","🇳🇱"),("netherl","🇳🇱"),("amsterdam","🇳🇱"),("амстер","🇳🇱"),
        ("финлянд","🇫🇮"),("finland","🇫🇮"),("хельсин","🇫🇮"),
        ("польш","🇵🇱"),("poland","🇵🇱"),("варшав","🇵🇱"),
        ("швец","🇸🇪"),("sweden","🇸🇪"),("франц","🇫🇷"),("france","🇫🇷"),("париж","🇫🇷"),
        ("сша","🇺🇸"),("usa","🇺🇸"),("america","🇺🇸"),("united states","🇺🇸"),
        ("англ","🇬🇧"),("london","🇬🇧"),("britain","🇬🇧"),("uk","🇬🇧"),
        ("япон","🇯🇵"),("japan","🇯🇵"),("токио","🇯🇵"),
        ("сингап","🇸🇬"),("singapore","🇸🇬"),
        ("турц","🇹🇷"),("turkey","🇹🇷"),("стамбул","🇹🇷"),
        ("канад","🇨🇦"),("canada","🇨🇦"),("дубай","🇦🇪"),("uae","🇦🇪"),("emirat","🇦🇪"),
        ("латв","🇱🇻"),("latvia","🇱🇻"),("эстон","🇪🇪"),("estonia","🇪🇪"),
        ("испан","🇪🇸"),("spain","🇪🇸"),("итал","🇮🇹"),("italy","🇮🇹"),
        ("швейцар","🇨🇭"),("swiss","🇨🇭"),("гонконг","🇭🇰"),("hong","🇭🇰"),
        ("корея","🇰🇷"),("korea","🇰🇷"),("индия","🇮🇳"),("india","🇮🇳"),
        ("казах","🇰🇿"),("kazakh","🇰🇿"),("украин","🇺🇦"),("ukrain","🇺🇦")
    ]
    for (k,v) in map { if n.contains(k) { return v } }
    return "🌐"
}

/// Флаг, уже вписанный в название сервера самой панелью.
///
/// Почти все панели ставят его в начало имени. Свой флаг слева от такого имени
/// давал два одинаковых значка подряд — вынимаем вписанный и показываем только
/// его, а имя оставляем без него.
func splitLeadingFlag(_ name: String) -> (name: String, flag: String?) {
    var rest = Substring(name.trimmingCharacters(in: .whitespaces))

    guard let first = rest.first,
          first.unicodeScalars.count == 2,
          first.unicodeScalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) })
    else {
        return (name, nil)
    }

    let flag = String(first)
    rest = rest.dropFirst()
    // Отделитель сразу после флага убираем, а дефис внутри имени
    // («germany - резерв») трогать нельзя — до него есть буквы.
    while let c = rest.first, c == " " || c == "·" || c == "-" || c == "|" {
        rest = rest.dropFirst()
    }

    let cleaned = String(rest).trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? (name, flag) : (cleaned, flag)
}

func parseServer(_ raw: String) -> Server? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let r = s.range(of: "://") else { return nil }
    let scheme = String(s[s.startIndex..<r.lowerBound]).lowercased()
    // Ровно то, что умеет собрать SingBoxConfig. Лишние схемы здесь означали бы
    // ключ, который добавляется и красиво выглядит, а падает при подключении.
    let ok = ["vless","vmess","trojan","ss","shadowsocks","socks","socks5",
              "hysteria2","hy2","tuic"]
    guard ok.contains(scheme) else { return nil }
    var name = ""
    if let h = s.firstIndex(of: "#") {
        name = String(s[s.index(after: h)...]).removingPercentEncoding ?? ""
    }
    if name.isEmpty { name = scheme.uppercased() }
    let proto: String
    switch scheme {
    case "hy2":         proto = "HYSTERIA2"
    case "shadowsocks": proto = "SS"
    case "socks5":      proto = "SOCKS"
    default:            proto = scheme.uppercased()
    }

    let transport = transportOf(s, scheme: scheme)
    let (displayName, embeddedFlag) = splitLeadingFlag(name)

    return Server(
        raw: s,
        name: displayName,
        proto: proto,
        transport: transport.uppercased(),
        isSupported: SingBoxConfig.supports(transport: transport),
        usesDatagrams: ["hysteria2", "hy2", "tuic"].contains(scheme),
        // Флаг из имени точнее нашего угадывания по словам: панель знает
        // страну сервера, а мы её только предполагаем.
        flag: embeddedFlag ?? flagFor(name)
    )
}

/// Транспорт указывают по-разному: в vmess он внутри base64-JSON, у остальных —
/// параметром `type` в ссылке.
private func transportOf(_ raw: String, scheme: String) -> String {
    if scheme == "vmess" {
        guard let data = Data(base64Encoded: padBase64(String(raw.dropFirst("vmess://".count)))),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "tcp"
        }
        if let net = json["net"] as? String, !net.isEmpty { return net }
        return "tcp"
    }

    guard let components = URLComponents(string: raw) else { return "tcp" }
    let type = components.queryItems?.first { $0.name == "type" }?.value ?? ""
    return type.isEmpty ? "tcp" : type
}

func padBase64(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "\n", with: "")
             .replacingOccurrences(of: "\r", with: "")
             .replacingOccurrences(of: "-", with: "+")
             .replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return t
}

// Палитра и тема живут в Theme.swift, строки интерфейса — в L10n.swift.

// MARK: - Главный экран

@MainActor
struct ContentView: View {
    /// Подписки и одиночные ключи живут в общем хранилище — оно же отвечает
    /// за сохранение и за то, какой сервер выбран.
    @ObservedObject private var store = ServerStore.shared


    // Анимация кнопки подключения.
    @State private var outerAngle: Double = 0
    @State private var innerAngle: Double = 0
    @State private var glow: CGFloat = 1
    @State private var boltScale: CGFloat = 1
    @State private var pressed = false

    /// Задержка, уже показанная в плашке на экране блокировки.
    @State private var lastReportedLatency: Int?

    @State private var showAdd = false
    @State private var showList = false
    @State private var showSettings = false
    @State private var input = ""
    @State private var status = ""
    /// Удачным ли был последний результат. Раньше это выяснялось поиском слова
    /// «Добавлено» в самой строке — на другом языке проверка молча ломалась.
    @State private var statusIsGood = false
    @State private var loading = false

    /// Контроллер — синглтон, мы его не создаём, поэтому ObservedObject, а не StateObject.
    @ObservedObject private var vpn = VPNController.shared
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var ping = PingMonitor()
    @ObservedObject private var probe = LatencyProbe.shared

    @Environment(\.scenePhase) private var scenePhase

    enum ConnState { case off, connecting, on }

    var selected: Server? { store.selected }

    /// Состояние UI выводится напрямую из статуса системы. Отдельного флага больше
    /// нет — раньше он расходился с реальностью, если VPN отваливался сам.
    private var state: ConnState {
        switch vpn.status {
        case .connected:              return .on
        case .connecting, .reasserting, .disconnecting: return .connecting
        default:                      return .off
        }
    }

    var body: some View {
        ZStack {
            JT.backdrop.ignoresSafeArea()
            ambientGlow

            VStack(spacing: 0) {
                header
                Spacer(minLength: 8)
                orb
                statusPill.padding(.top, 20)
                timerLabel.padding(.top, 10)
                pingLabel.padding(.top, 8)
                // Своё сообщение: проверка сервера перед подключением.
                //
                // Показываем здесь же, где ошибки ядра, — человек смотрит в
                // одно место и не гадает, почему ничего не произошло.
                if !status.isEmpty {
                    Text(status)
                        .foregroundColor(statusIsGood ? JT.green : JT.accent)
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                }

                if let err = vpn.errorMessage {
                    // Сообщение от ядра бывает длинным, а скопировать его нужно
                    // целиком — иначе причину сбоя не разобрать.
                    Text(err)
                        .foregroundColor(JT.red)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                        .padding(.horizontal, 20)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 8)
                troubleCard.padding(.horizontal, 20).padding(.bottom, 10)
                locationCard.padding(.horizontal, 20)
                addButton.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
            }
        }
        .onAppear {
            // Приложение могли открыть при уже поднятом туннеле — тогда
            // onChange не сработает, и замер надо запустить самим.
            handle(vpn.status)
        }
        .onChange(of: ping.latency) { _, _ in
            #if canImport(ActivityKit)
            guard vpn.status == .connected, let started = vpn.connectedDate else { return }
            guard ping.latency != lastReportedLatency else { return }
            lastReportedLatency = ping.latency
            LiveActivityController.shared.update(
                serverName: selected?.name ?? "Zyng",
                flag: selected?.flag ?? "🌐",
                connectedAt: started,
                latency: ping.latency,
                detail: activityDetail
            )
            #endif
        }
        .sheet(isPresented: $showAdd)  { addSheet }
        .sheet(isPresented: $showList) { serverListSheet }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings) { showSettings = false }
        }
        .onChange(of: vpn.status) { _, newStatus in
            handle(newStatus)
        }
        // Тема применяется к корню — отсюда её наследуют и открытые поверх
        // листы, иначе настройки оставались бы в системной теме.
        .preferredColorScheme(settings.theme.colorScheme)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Пока приложение было свёрнуто, уведомления о смене статуса не
            // приходили, а показанная задержка успела устареть.
            Task {
                await vpn.refresh()

                if vpn.status == .connected {
                    ping.refreshNow()
                    // Плашку могли не успеть создать — например, туннель
                    // подняли, пока приложение было свёрнуто.
                    startLiveActivity()
                } else {
                    #if canImport(ActivityKit)
                    // Убираем плашку, только УБЕДИВШИСЬ, что туннеля нет.
                    // Раньше проверка шла до опроса системы: при холодном
                    // старте статус ещё «неизвестен», и плашка от живого
                    // соединения тут же гасла.
                    LiveActivityController.shared.cleanupStale()
                    #endif
                }
            }
        }
    }

    private func handle(_ newStatus: NEVPNStatus) {
        switch newStatus {
        case .connected:
            ping.start()
            lastReportedLatency = nil
            startLiveActivity()
            // Сообщение о проверке больше не нужно: соединение состоялось.
            status = ""
        case .connecting, .reasserting:
            // Анимация кольца сама ускоряется по состоянию — здесь делать нечего.
            break
        default:
            ping.stop()
            #if canImport(ActivityKit)
            LiveActivityController.shared.stop()
            #endif
        }
    }

    /// Плашка на экране блокировки. Время в ней система отсчитывает сама по
    /// дате подключения, поэтому обновлять её каждую секунду не нужно —
    /// и она не «замерзает», пока приложение спит.
    private func startLiveActivity() {
        #if canImport(ActivityKit)
        guard let started = vpn.connectedDate else { return }
        LiveActivityController.shared.start(
            serverName: selected?.name ?? "Zyng",
            flag: selected?.flag ?? "🌐",
            connectedAt: started,
            latency: ping.latency,
            detail: activityDetail
        )
        #endif
    }

    /// Подпись под названием сервера в плашке: протокол и транспорт.
    private var activityDetail: String {
        guard let selected else { return "" }
        return "\(selected.proto) · \(selected.transport)"
    }

    /// Мягкое свечение за кнопкой, окрашенное по состоянию.
    ///
    /// Раньше фон был ровной заливкой, и весь экран держался на одной круглой
    /// кнопке посередине. Подсветка связывает её с фоном и делает переход
    /// «отключено → защищено» заметным целиком, а не только в самой кнопке.
    /// Нажатия не перехватывает — это чистое оформление.
    private var ambientGlow: some View {
        let color: Color = {
            switch state {
            case .on:         return JT.green
            case .connecting: return JT.accent
            case .off:        return JT.sub
            }
        }()

        return RadialGradient(
            colors: [color.opacity(state == .off ? 0.10 : 0.28), .clear],
            center: .center,
            startRadius: 0,
            endRadius: 340
        )
        .frame(height: 620)
        .blur(radius: 60)
        // Кнопка стоит выше середины экрана — свечение держим под ней.
        .offset(y: -70)
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.0), value: state)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                ZyngLogo(size: 34)
                Text("Zyng").font(.system(size: 19, weight: .heavy))
                    .foregroundColor(JT.text)
            }
            Spacer()

            HStack(spacing: 10) {
                Button {
                    haptic()
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(JT.sub)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(JT.card)
                            .overlay(Circle().stroke(JT.stroke, lineWidth: 1)))
                }

                Button {
                    haptic()
                    showList = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(JT.sub)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(JT.card)
                            .overlay(Circle().stroke(JT.stroke, lineWidth: 1)))
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    private var orb: some View {
        let color: Color = state == .on ? JT.green : (state == .connecting ? JT.accent : JT.sub)

        return Button {
            tapConnect()
        } label: {
            ZStack {
                // Свечение: дышит при подключении и в процессе, спокойно в покое.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [color.opacity(0.35), color.opacity(0.02)],
                            center: .center, startRadius: 30, endRadius: 140
                        )
                    )
                    .frame(width: 270, height: 270)
                    .blur(radius: 14)
                    .scaleEffect(glow)
                    .opacity(state == .off ? 0.5 : 1)

                // Неподвижная дорожка под дугами.
                //
                // Без неё кольца читались как две случайные чёрточки в пустоте:
                // видно движение, но не видно круга, по которому оно идёт.
                // Дорожка задаёт форму, и дуги превращаются в стрелку на шкале.
                Circle()
                    .stroke(JT.stroke.opacity(0.55), lineWidth: 1)
                    .frame(width: 236, height: 236)

                // Внешнее кольцо: разомкнутая дуга, вращается по часовой.
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(
                        AngularGradient(
                            colors: [color.opacity(0), color.opacity(0.55), color.opacity(0)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .frame(width: 236, height: 236)
                    .rotationEffect(.degrees(outerAngle))

                // Внутреннее кольцо крутится в обратную сторону — так движение
                // читается, даже когда скорость небольшая.
                Circle()
                    .trim(from: 0, to: 0.45)
                    .stroke(
                        AngularGradient(
                            colors: [color.opacity(0), color.opacity(0.7), color.opacity(0)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .frame(width: 196, height: 196)
                    .rotationEffect(.degrees(innerAngle))

                // Ободок вокруг кнопки — ровный, чтобы форма читалась.
                Circle()
                    .stroke(color.opacity(0.18), lineWidth: 1)
                    .frame(width: 216, height: 216)

                // Сама кнопка.
                Circle()
                    .fill(
                        LinearGradient(colors: [JT.cardHi, JT.card],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    // Блик сверху. Плоский круг выглядел наклейкой; светлое
                    // пятно у верхнего края делает из него физическую кнопку,
                    // которую хочется нажать.
                    .overlay(
                        Circle().fill(
                            RadialGradient(
                                colors: [.white.opacity(0.10), .clear],
                                center: .init(x: 0.32, y: 0.20),
                                startRadius: 2, endRadius: 130
                            )
                        )
                    )
                    .frame(width: 168, height: 168)
                    .overlay(Circle().stroke(color.opacity(0.55), lineWidth: 2))
                    .shadow(color: color.opacity(0.4), radius: 26)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                    .scaleEffect(pressed ? 0.94 : 1)

                VStack(spacing: 8) {
                    Image(systemName: state == .on ? "bolt.fill" : "power")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(color)
                        .scaleEffect(state == .on ? boltScale : 1)
                        // Значок не подменяется в кадре, а перетекает —
                        // системная замена символа, ради неё же и одинаковый
                        // размер шрифта у обоих.
                        .contentTransition(.symbolEffect(.replace))

                    Text(state == .on ? tr("ВКЛ", "ON")
                                     : (state == .connecting ? "…" : tr("ВЫКЛ", "OFF")))
                        .font(.system(size: 13, weight: .bold)).tracking(2)
                        .foregroundColor(JT.sub)
                        .contentTransition(.opacity)
                }
                .scaleEffect(pressed ? 0.94 : 1)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressed)
            // Медленная мягкая пружина.
            //
            // Смена состояния — главное событие на экране, и раньше она
            // проскакивала быстрее, чем взгляд успевал за ней: цвет менялся
            // почти мгновенно, и переход не читался. Секунда с небольшим
            // доводчиком превращает его в движение, за которым приятно
            // наблюдать. Быстрее здесь не лучше.
            .animation(.spring(response: 1.0, dampingFraction: 0.82), value: state)
        }
        .buttonStyle(.plain)
        // Нажатие отслеживаем сами: у кнопки со своим оформлением нет
        // встроенной подсветки, а отклик на палец нужен.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .onAppear { startOrbAnimation() }
        .onChange(of: state) { _, _ in startOrbAnimation() }
    }

    /// Кольца крутятся всегда, но с разной скоростью: быстро при подключении,
    /// спокойно в остальное время. Свечение и молния дышат только когда
    /// соединение активно.
    private func startOrbAnimation() {
        let outerDuration: Double
        let innerDuration: Double

        // Медленно. Очень медленно — и это намеренно.
        //
        // Круг диаметром в четверть экрана при обороте за десяток секунд
        // выглядит вертушкой: движение перетягивает на себя всё внимание, хотя
        // сообщать ему нечего. Здесь оборот занимает полторы-две минуты в
        // покое и полминуты в работе — глаз замечает, что живое, но следить не
        // тянет. Даже на время подключения оборот идёт шесть секунд: этого с
        // избытком хватает, чтобы прочитать «идёт работа».
        switch state {
        case .connecting: outerDuration = 6;   innerDuration = 8
        case .on:         outerDuration = 34;  innerDuration = 46
        case .off:        outerDuration = 90;  innerDuration = 120
        }

        // Сначала возвращаем углы в ноль БЕЗ анимации.
        //
        // Иначе кольца замирали. Первый вызов доводил угол до 360 и там его
        // оставлял; при следующей смене состояния мы снова просили
        // «анимируй до 360», то есть из 360 в 360 — движения на ноль
        // градусов, и вращение прекращалось насовсем. Ровно это и выглядело
        // как «включил VPN, и всё застыло».
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            outerAngle = 0
            innerAngle = 0
        }

        withAnimation(.linear(duration: outerDuration).repeatForever(autoreverses: false)) {
            outerAngle = 360
        }
        withAnimation(.linear(duration: innerDuration).repeatForever(autoreverses: false)) {
            innerAngle = -360
        }

        if state == .off {
            withAnimation(.easeInOut(duration: 0.9)) {
                glow = 1
                boltScale = 1
            }
        } else {
            // Дыхание замедлено почти вдвое: на глаз это спокойный вдох-выдох,
            // а не мигание. Размах тоже меньше — движение должно ощущаться,
            // а не бросаться в глаза.
            withAnimation(.easeInOut(duration: state == .on ? 6.0 : 2.6).repeatForever()) {
                glow = state == .on ? 1.06 : 1.11
            }
            if state == .on {
                withAnimation(.easeInOut(duration: 5.0).repeatForever()) {
                    boltScale = 1.05
                }
            }
        }
    }

    private var statusPill: some View {
        let t: String; let c: Color
        switch state {
        case .off:        t = tr("Отключено", "Disconnected");   c = JT.sub
        case .connecting: t = tr("Подключение…", "Connecting…");  c = JT.accent
        case .on:         t = tr("Защищено", "Protected");        c = JT.green
        }
        return HStack(spacing: 8) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(t).font(.system(size: 14, weight: .semibold)).foregroundColor(c)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Capsule().fill(JT.card).overlay(Capsule().stroke(JT.stroke, lineWidth: 1)))
        // Надпись меняется мягко, а не подменяется рывком в тот же кадр, что и
        // цвет кнопки: переход читается как одно движение.
        .animation(.easeInOut(duration: 0.8), value: state)
    }

    /// Время считается прямо при отрисовке из момента подключения, который
    /// хранит система. Ни накопителя, ни таймера в состоянии экрана нет —
    /// нечему отставать после сворачивания и нечему сбрасываться в ноль.
    private var timerLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds: Int = {
                guard state == .on, let started = vpn.connectedDate else { return 0 }
                return max(0, Int(context.date.timeIntervalSince(started)))
            }()

            Text(timeString(seconds))
                // Крупнее и округлым начертанием.
                //
                // Пока туннель поднят, это единственная живая цифра на экране,
                // и прежним мелким моноширинным шрифтом она читалась как
                // служебная строчка. Округлое начертание с широкими цифрами
                // выглядит как время на часах — чем оно, по сути, и является.
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(state == .on ? JT.text : JT.sub.opacity(0.45))
                .monospacedDigit()
                .animation(.easeInOut(duration: 0.8), value: state)
        }
    }

    /// Задержка показывается только при активном подключении: без туннеля
    /// это была бы скорость обычной сети, а не VPN.
    @ViewBuilder
    private var pingLabel: some View {
        if state == .on {
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 11, weight: .semibold))

                if let ms = ping.latency {
                    Text("\(ms) \(tr("мс", "ms"))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                } else if ping.failed {
                    // В самой плашке — коротко. Разбор причины не влезает в
                    // строку и живёт ниже, отдельной карточкой.
                    Text(tr("нет ответа", "no response"))
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text(tr("измеряю…", "measuring…"))
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundColor(pingColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(pingColor.opacity(0.12))
                    .overlay(Capsule().stroke(pingColor.opacity(0.25), lineWidth: 1))
            )
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .animation(.easeOut(duration: 0.2), value: ping.latency)
        }
    }

    /// Разбор причины, когда туннель поднят, а трафика нет.
    ///
    /// Это самая обидная из всех неисправностей: система показывает
    /// «Подключено», значок VPN горит, а не открывается ничего — и приложение
    /// молчит, потому что с его точки зрения всё хорошо. Ответ всё это время
    /// лежал в журнале ядра, куда человек не смотрит и не должен.
    @ViewBuilder
    private var troubleCard: some View {
        if state == .on, ping.failed, !ping.failureReason.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(JT.red)

                Text(ping.failureReason)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(JT.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(JT.red.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(JT.red.opacity(0.28), lineWidth: 1)
                    )
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeOut(duration: 0.25), value: ping.failureReason)
        }
    }

    /// Зелёный до 100 мс, жёлтый до 250, дальше красный.
    private var pingColor: Color {
        guard let ms = ping.latency else { return JT.sub }
        return latencyColor(ms)
    }

    private func latencyColor(_ ms: Int) -> Color {
        switch ms {
        case ..<100:  return JT.green
        case ..<250:  return JT.accent
        default:      return JT.red
        }
    }

    private var locationCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Подпись над карточкой.
            //
            // Без неё карточка читалась как обычная надпись: флаг, название,
            // стрелка — и совсем не очевидно, что это выбор сервера и что по
            // ней нужно нажать. Одно слово снимает вопрос.
            Text(tr("СЕРВЕР", "SERVER"))
                .font(.system(size: 10, weight: .bold))
                .tracking(1.4)
                .foregroundColor(JT.sub.opacity(0.7))
                .padding(.leading, 4)

            locationButton
        }
    }

    private var locationButton: some View {
        Button { showList = true } label: {
            HStack(spacing: 14) {
                Text(selected?.flag ?? "🌐").font(.system(size: 30))
                VStack(alignment: .leading, spacing: 3) {
                    Text(selected?.name ?? tr("Сервер не выбран", "No server selected"))
                        .foregroundColor(JT.text)
                        .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(selected.map { "\($0.proto) · \($0.transport)" }
                             ?? tr("Добавь ключ или подписку", "Add a key or subscription"))
                            .foregroundColor(JT.sub).font(.system(size: 12))

                        if let selected, !selected.isSupported {
                            Text(tr("не поддерживается", "unsupported"))
                                .foregroundColor(JT.red)
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                }
                Spacer()

                // Задержка выбранного сервера, если её уже мерили в списке.
                // Заново не меряем: показываем то, что известно, — так на
                // главном экране сразу видно, насколько удачен выбор.
                if state != .on,
                   let selected,
                   case .ms(let value)? = probe.latency(for: selected) {
                    Text("\(value) \(tr("мс", "ms"))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(latencyColor(value))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(latencyColor(value).opacity(0.12))
                                .overlay(Capsule().stroke(latencyColor(value).opacity(0.25),
                                                          lineWidth: 1))
                        )
                }

                Image(systemName: "chevron.right").foregroundColor(JT.sub)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18).fill(JT.card)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(JT.stroke, lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }

    private var addButton: some View {
        Button { status = ""; showAdd = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text(tr("Добавить ключ / подписку", "Add key / subscription"))
            }
            .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors:[JT.accent, Color(hex:"7A5CFF")],
                                     startPoint:.leading, endPoint:.trailing)))
        }
    }

    private var serverListSheet: some View {
        ServerListView(
            store: store,
            onPicked: { showList = false },
            onAdd: { showList = false; showAdd = true }
        )
    }

    private var addSheet: some View {
        ZStack {
            JT.bg1.ignoresSafeArea()
            VStack(spacing: 16) {
                Capsule().fill(JT.stroke).frame(width: 40, height: 5).padding(.top, 10)
                Text(tr("Добавить ключ / подписку", "Add key / subscription")).foregroundColor(JT.text)
                    .font(.system(size: 18, weight: .bold)).padding(.top, 6)

                Text(tr("Вставь ключ vless:// vmess:// trojan:// ss://\nили ссылку-подписку https://…",
                        "Paste a vless:// vmess:// trojan:// ss:// key\nor an https:// subscription link"))
                    .foregroundColor(JT.sub).font(.system(size: 13))
                    .multilineTextAlignment(.center)

                TextField("", text: $input, axis: .vertical)
                    .placeholder(when: input.isEmpty) {
                        Text(tr("vless://…  или  https://подписка", "vless://…  or  https://subscription"))
                            .foregroundColor(JT.sub.opacity(0.6))
                    }
                    .foregroundColor(JT.text).tint(JT.accent)
                    .font(.system(size: 14))
                    .padding(14).frame(minHeight: 110, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(JT.card)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(JT.stroke, lineWidth: 1)))
                    .autocorrectionDisabled(true)
                    .jtNoAutocap()
                    .padding(.horizontal, 20)

                Button { input = jtClipboard() ?? input } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                        Text(tr("Вставить из буфера", "Paste from clipboard"))
                    }.font(.system(size: 13, weight: .semibold)).foregroundColor(JT.accent)
                }

                if !status.isEmpty {
                    Text(status)
                        .foregroundColor(statusIsGood ? JT.green : JT.sub)
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.center).padding(.horizontal, 20)
                }

                Button(action: addKey) {
                    HStack(spacing: 8) {
                        if loading { ProgressView().tint(.white) }
                        Text(loading ? tr("Загружаю…", "Loading…") : tr("Добавить", "Add"))
                    }
                    .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(colors:[JT.accent, Color(hex:"7A5CFF")],
                                             startPoint:.leading, endPoint:.trailing)))
                }.padding(.horizontal, 20).disabled(loading)

                Button(tr("Закрыть", "Close")) { showAdd = false }.foregroundColor(JT.sub)
                Spacer()
            }
        }
    }

    /// Вибрация только если она включена в настройках.
    private func haptic() {
        if settings.haptics { jtHaptic() }
    }

    private func tapConnect() {
        guard let selected else { showAdd = true; return }
        haptic()

        switch state {
        case .off:
            // Просто подключаемся.
            //
            // В сборке 48 здесь стояла проверка сервера ПЕРЕД подключением, и
            // она запрещала соединение, если не отвечала сама. Это оказалось
            // грубой ошибкой: тот же ключ прекрасно работал в других клиентах,
            // а Zyng отказывался даже пробовать.
            //
            // Замер задержки — вещь приблизительная. Он бьётся в TCP-порт
            // напрямую, а настоящий клиент подключается иначе, и у него есть
            // свои пути: повтор, другой маршрут, обход. Отказ замера НЕ
            // означает, что сервер недоступен, и решать за ядро он не вправе.
            //
            // Проверка, идёт ли трафик, осталась — но ПОСЛЕ подключения, в
            // PingMonitor: там она никому не мешает и только сообщает.
            Task { await vpn.connect(key: selected.raw) }
        case .connecting:
            break
        case .on:
            vpn.disconnect()
        }
    }

    /// Адрес и порт ключа для сообщения об ошибке. Без пароля и UUID.
    private static func endpointText(of raw: String) -> (String, String) {
        guard let end = try? SingBoxConfig.serverEndpoint(from: raw) else {
            return ("—", "—")
        }
        return (end.host, String(end.port))
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d:%02d", s/3600, (s%3600)/60, s%60)
    }

    func addKey() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusIsGood = false
            status = tr("Пусто", "Empty")
            return
        }

        // Ссылка — это подписка, она будет обновляться сама.
        if text.lowercased().hasPrefix("http") {
            loading = true
            statusIsGood = false
            status = tr("Загружаю подписку…", "Loading subscription…")
            Task {
                await store.addSubscription(url: text)
                loading = false
                if let error = store.lastError {
                    statusIsGood = false
                    status = error
                } else {
                    statusIsGood = true
                    status = tr("Подписка добавлена", "Subscription added")
                    input = ""
                    showAdd = false
                }
            }
            return
        }

        let added = store.addSingleKeys(from: text)
        statusIsGood = added > 0
        status = added > 0
            ? tr("Добавлено ключей: \(added)", "Keys added: \(added)")
            : tr("Не похоже на ключ (нужен vless:// и т.п.)",
                 "Doesn't look like a key (vless:// and similar)")
        if added > 0 {
            input = ""
            showAdd = false
        }
    }

}

// MARK: - Placeholder helper

extension View {
    func placeholder<Content: View>(when show: Bool,
                                    alignment: Alignment = .topLeading,
                                    @ViewBuilder placeholder: () -> Content) -> some View {
        ZStack(alignment: alignment) {
            placeholder().opacity(show ? 1 : 0).padding(.leading, 4).padding(.top, 2)
            self
        }
    }
}

#Preview { ContentView() }
