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
    let flag: String
    var ping: Int? = nil
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

func parseServer(_ raw: String) -> Server? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let r = s.range(of: "://") else { return nil }
    let scheme = String(s[s.startIndex..<r.lowerBound]).lowercased()
    let ok = ["vless","vmess","trojan","ss","socks","socks5","wireguard",
              "hysteria2","hy2","tuic","hysteria"]
    guard ok.contains(scheme) else { return nil }
    var name = ""
    if let h = s.firstIndex(of: "#") {
        name = String(s[s.index(after: h)...]).removingPercentEncoding ?? ""
    }
    if name.isEmpty { name = scheme.uppercased() }
    let proto = scheme == "hy2" ? "HYSTERIA2" : scheme.uppercased()
    return Server(raw: s, name: name, proto: proto, flag: flagFor(name))
}

func padBase64(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "\n", with: "")
             .replacingOccurrences(of: "\r", with: "")
             .replacingOccurrences(of: "-", with: "+")
             .replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return t
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

private enum JT {
    static let bg1     = Color(hex:"0E1014")
    static let bg2     = Color(hex:"171A20")
    static let card    = Color(hex:"1D2129")
    static let cardHi  = Color(hex:"272C36")
    static let stroke  = Color(hex:"2E343F")
    static let text    = Color.white
    static let sub     = Color(hex:"8A94A6")
    static let accent  = Color(hex:"5B8CFF")
    static let green   = Color(hex:"39D98A")
    static let red     = Color(hex:"FF5C5C")
}

// MARK: - Главный экран

@MainActor
struct ContentView: View {
    @AppStorage("zyng_keys") private var savedRaw: String = ""
    /// Выбранный сервер запоминаем по строке ключа: `Server.id` генерируется
    /// заново при каждом парсинге, поэтому по нему выбор не переживал перезапуск.
    @AppStorage("zyng_selected") private var savedSelected: String = ""

    @State private var servers: [Server] = []
    @State private var selectedID: UUID?

    @State private var connectedAt: Date?
    @State private var elapsed = 0
    @State private var pulse = false

    @State private var showAdd = false
    @State private var showList = false
    @State private var input = ""
    @State private var status = ""
    @State private var loading = false

    /// Контроллер — синглтон, мы его не создаём, поэтому ObservedObject, а не StateObject.
    @ObservedObject private var vpn = VPNController.shared

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum ConnState { case off, connecting, on }

    var selected: Server? { servers.first { $0.id == selectedID } }

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
            LinearGradient(colors:[JT.bg1, JT.bg2], startPoint:.top, endPoint:.bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 8)
                orb
                statusPill.padding(.top, 18)
                timerLabel.padding(.top, 6)
                if let err = vpn.errorMessage {
                    Text(err).foregroundColor(JT.red).font(.system(size: 12))
                        .padding(.top, 8).padding(.horizontal, 20).multilineTextAlignment(.center)
                }
                Spacer(minLength: 8)
                locationCard.padding(.horizontal, 20)
                addButton.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
            }
        }
        .onAppear(perform: load)
        .sheet(isPresented: $showAdd)  { addSheet }
        .sheet(isPresented: $showList) { serverListSheet }
        .onChange(of: vpn.status) { _, newStatus in
            handle(newStatus)
        }
        .onReceive(ticker) { _ in
            // Считаем от момента подключения, а не счётчиком: счётчик замирал,
            // когда приложение уходило в фон, и время показывалось неверно.
            guard let connectedAt, vpn.status == .connected else { return }
            elapsed = Int(Date().timeIntervalSince(connectedAt))
        }
    }

    private func handle(_ newStatus: NEVPNStatus) {
        switch newStatus {
        case .connected:
            if connectedAt == nil { connectedAt = Date() }
            stopPulse()
        case .connecting, .reasserting:
            startPulse()
        default:
            connectedAt = nil
            elapsed = 0
            stopPulse()
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(colors:[JT.accent, Color(hex:"7A5CFF")],
                                             startPoint:.topLeading, endPoint:.bottomTrailing))
                        .frame(width: 34, height: 34)
                    Text("Z").font(.system(size: 20, weight: .black)).foregroundColor(.white)
                }
                Text("Zyng").font(.system(size: 19, weight: .heavy))
                    .foregroundColor(JT.text)
            }
            Spacer()
            Button { showList = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(JT.sub)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(JT.card))
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
                Circle().fill(color.opacity(0.14)).frame(width: 250, height: 250).blur(radius: 12)
                    .scaleEffect(pulse ? 1.06 : 0.94)
                Circle().stroke(color.opacity(0.25), lineWidth: 1).frame(width: 230, height: 230)
                Circle().stroke(color.opacity(0.35), lineWidth: 1).frame(width: 190, height: 190)
                Circle()
                    .fill(LinearGradient(colors:[JT.cardHi, JT.card],
                                         startPoint:.topLeading, endPoint:.bottomTrailing))
                    .frame(width: 168, height: 168)
                    .overlay(Circle().stroke(color.opacity(0.55), lineWidth: 2))
                    .shadow(color: color.opacity(0.35), radius: 24)
                VStack(spacing: 8) {
                    Image(systemName: state == .on ? "bolt.fill" : "power")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(color)
                    Text(state == .on ? "ВКЛ" : (state == .connecting ? "…" : "ВЫКЛ"))
                        .font(.system(size: 13, weight: .bold)).tracking(2)
                        .foregroundColor(JT.sub)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var statusPill: some View {
        let t: String; let c: Color
        switch state {
        case .off:        t = "Отключено";     c = JT.sub
        case .connecting: t = "Подключение…";  c = JT.accent
        case .on:         t = "Защищено";      c = JT.green
        }
        return HStack(spacing: 8) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(t).font(.system(size: 14, weight: .semibold)).foregroundColor(c)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Capsule().fill(JT.card).overlay(Capsule().stroke(JT.stroke, lineWidth: 1)))
    }

    private var timerLabel: some View {
        Text(timeString(elapsed))
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundColor(state == .on ? JT.text : JT.sub.opacity(0.5))
    }

    private var locationCard: some View {
        Button { showList = true } label: {
            HStack(spacing: 14) {
                Text(selected?.flag ?? "🌐").font(.system(size: 30))
                VStack(alignment: .leading, spacing: 3) {
                    Text(selected?.name ?? "Сервер не выбран")
                        .foregroundColor(JT.text)
                        .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(selected?.proto ?? "Добавь ключ или подписку")
                            .foregroundColor(JT.sub).font(.system(size: 12))
                        if let p = selected?.ping {
                            Text("· \(p) ms")
                                .foregroundColor(p < 150 ? JT.green : JT.sub)
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                }
                Spacer()
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
                Text("Добавить ключ / подписку")
            }
            .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors:[JT.accent, Color(hex:"7A5CFF")],
                                     startPoint:.leading, endPoint:.trailing)))
        }
    }

    private var serverListSheet: some View {
        ZStack {
            JT.bg1.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Серверы").foregroundColor(JT.text)
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                    Text("\(servers.count)").foregroundColor(JT.sub)
                        .font(.system(size: 14, weight: .semibold))
                    Button { showList = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(JT.sub)
                            .font(.system(size: 24))
                    }.padding(.leading, 6)
                }.padding(20)

                if servers.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack").font(.system(size: 40)).foregroundColor(JT.sub)
                        Text("Пока нет серверов").foregroundColor(JT.sub)
                        Button("Добавить ключ") { showList = false; showAdd = true }
                            .foregroundColor(JT.accent).font(.system(size: 15, weight: .semibold))
                    }
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(servers) { sv in serverRow(sv) }
                        }.padding(.horizontal, 16).padding(.bottom, 24)
                    }
                }
            }
        }
    }

    private func serverRow(_ sv: Server) -> some View {
        HStack(spacing: 12) {
            Text(sv.flag).font(.system(size: 24))
            VStack(alignment: .leading, spacing: 2) {
                Text(sv.name).foregroundColor(JT.text)
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(sv.proto).foregroundColor(JT.sub).font(.system(size: 11))
            }
            Spacer()
            if sv.id == selectedID {
                Image(systemName: "checkmark.circle.fill").foregroundColor(JT.green)
                    .font(.system(size: 20))
            }
            Button {
                servers.removeAll { $0.id == sv.id }
                if selectedID == sv.id {
                    selectedID = servers.first?.id
                    vpn.disconnect()
                }
                save()
            } label: {
                Image(systemName: "trash").foregroundColor(JT.red.opacity(0.8))
                    .font(.system(size: 15))
            }.padding(.leading, 4)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(sv.id == selectedID ? JT.cardHi : JT.card)
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(sv.id == selectedID ? JT.green.opacity(0.4) : JT.stroke, lineWidth: 1)))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { selectedID = sv.id }
            save()
            showList = false
        }
    }

    private var addSheet: some View {
        ZStack {
            JT.bg1.ignoresSafeArea()
            VStack(spacing: 16) {
                Capsule().fill(JT.stroke).frame(width: 40, height: 5).padding(.top, 10)
                Text("Добавить ключ / подписку").foregroundColor(JT.text)
                    .font(.system(size: 18, weight: .bold)).padding(.top, 6)

                Text("Вставь ключ vless:// vmess:// trojan:// ss://\nили ссылку-подписку https://…")
                    .foregroundColor(JT.sub).font(.system(size: 13))
                    .multilineTextAlignment(.center)

                TextField("", text: $input, axis: .vertical)
                    .placeholder(when: input.isEmpty) {
                        Text("vless://…  или  https://подписка")
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
                        Text("Вставить из буфера")
                    }.font(.system(size: 13, weight: .semibold)).foregroundColor(JT.accent)
                }

                if !status.isEmpty {
                    Text(status)
                        .foregroundColor(status.contains("Добавлено") ? JT.green : JT.sub)
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.center).padding(.horizontal, 20)
                }

                Button(action: addKey) {
                    HStack(spacing: 8) {
                        if loading { ProgressView().tint(.white) }
                        Text(loading ? "Загружаю…" : "Добавить")
                    }
                    .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(colors:[JT.accent, Color(hex:"7A5CFF")],
                                             startPoint:.leading, endPoint:.trailing)))
                }.padding(.horizontal, 20).disabled(loading)

                Button("Закрыть") { showAdd = false }.foregroundColor(JT.sub)
                Spacer()
            }
        }
    }

    private func tapConnect() {
        guard let selected else { showAdd = true; return }
        jtHaptic()

        switch state {
        case .off:
            startPulse()
            Task { await vpn.connect(key: selected.raw) }
        case .connecting:
            break
        case .on:
            vpn.disconnect()
        }
    }

    private func startPulse() {
        pulse = false
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
    }

    private func stopPulse() {
        withAnimation(.easeInOut(duration: 0.2)) { pulse = false }
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%02d:%02d:%02d", s/3600, (s%3600)/60, s%60)
    }

    func addKey() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { status = "Пусто"; return }

        if text.lowercased().hasPrefix("http") {
            loading = true; status = "Загружаю подписку…"
            Task {
                let list = await importSubscription(text)
                await MainActor.run {
                    loading = false
                    let existing = Set(servers.map { $0.raw })
                    let fresh = list.filter { !existing.contains($0.raw) }
                    servers.append(contentsOf: fresh)
                    if selectedID == nil { selectedID = servers.first?.id }
                    status = list.isEmpty
                        ? "Подписка пустая или недоступна"
                        : "Добавлено: \(fresh.count) (всего \(servers.count))"
                    save()
                    if !list.isEmpty { input = ""; showAdd = false }
                }
            }
            return
        }

        var added = 0
        for line in text.split(whereSeparator: \.isNewline) {
            if let sv = parseServer(String(line)) {
                if !servers.contains(where: { $0.raw == sv.raw }) { servers.append(sv); added += 1 }
            }
        }
        if selectedID == nil { selectedID = servers.first?.id }
        status = added > 0 ? "Добавлено: \(added)" : "Не похоже на ключ (нужен vless:// и т.п.)"
        save()
        if added > 0 { input = ""; showAdd = false }
    }

    func importSubscription(_ urlStr: String) async -> [Server] {
        guard let url = URL(string: urlStr) else { return [] }
        let uas = ["Happ/1.0", "v2rayNG/1.8.5", "Streisand", "SFI/2.0", "Zyng/1.0"]
        for ua in uas {
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.setValue(jtHWID(), forHTTPHeaderField: "x-hwid")
            req.setValue("ios", forHTTPHeaderField: "x-device-os")
            req.setValue(jtDeviceOS(), forHTTPHeaderField: "x-ver-os")
            req.setValue(jtDeviceModel(), forHTTPHeaderField: "x-device-model")
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                var text = String(data: data, encoding: .utf8) ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = Data(base64Encoded: padBase64(trimmed)),
                   let dec = String(data: d, encoding: .utf8), dec.contains("://") {
                    text = dec
                }
                let list = text.split(whereSeparator: \.isNewline).compactMap { parseServer(String($0)) }
                if !list.isEmpty { return list }
            } catch { continue }
        }
        return []
    }

    func save() {
        savedRaw = servers.map { $0.raw }.joined(separator: "\n")
        savedSelected = selected?.raw ?? ""
    }

    func load() {
        servers = savedRaw.split(whereSeparator: \.isNewline).compactMap { parseServer(String($0)) }
        selectedID = servers.first { $0.raw == savedSelected }?.id ?? servers.first?.id
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
