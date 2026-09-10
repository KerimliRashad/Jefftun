import SwiftUI

// UIPasteboard живёт в UIKit. SwiftUI обычно тянет его за собой, но
// полагаться на это не стоит — импортируем явно.
#if canImport(UIKit)
import UIKit
#endif

@MainActor
struct SettingsView: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject private var vpn = VPNController.shared

    let onClose: () -> Void

    /// DNS нельзя менять на лету: конфигурация уходит в ядро при запуске
    /// туннеля, поэтому изменение вступит в силу после переподключения.
    private var needsReconnect: Bool {
        vpn.status == .connected && dnsChanged
    }

    @State private var dnsChanged = false
    @State private var showCoreLog = false
    @State private var coreLog = ""

    var body: some View {
        ZStack {
            JT.backdrop.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 22) {
                        appearanceSection
                        dnsSection
                        behaviourSection
                        aboutSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
                }
            }
        }
        .sheet(isPresented: $showCoreLog) { coreLogSheet }
    }

    /// Журнал ядра: показать и дать скопировать.
    ///
    /// Текст выделяемый и есть кнопка «Скопировать»: этот журнал нужен, чтобы
    /// его кому-то отправить, а переписывать с экрана телефона руками —
    /// заведомо мимо.
    private var coreLogSheet: some View {
        ZStack {
            JT.backdrop.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text(tr("Журнал ядра", "Core log"))
                        .foregroundColor(JT.text)
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                    Button {
                        UIPasteboard.general.string = coreLog
                        jtHaptic()
                    } label: {
                        Text(tr("Скопировать", "Copy"))
                            .foregroundColor(JT.accent)
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Button { showCoreLog = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(JT.sub)
                            .font(.system(size: 24))
                    }
                    .padding(.leading, 12)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)

                ScrollView {
                    Text(coreLog)
                        .foregroundColor(JT.text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(JT.bg2)
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .stroke(JT.stroke, lineWidth: 1))
                        )
                        .padding(.horizontal, 18)
                        .padding(.bottom, 28)
                }
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
    }

    // MARK: - Шапка

    private var header: some View {
        HStack {
            Text(tr("Настройки", "Settings"))
                .foregroundColor(JT.text)
                .font(.system(size: 22, weight: .bold))

            Spacer()

            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(JT.sub)
                    .font(.system(size: 26))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    // MARK: - Оформление

    private var appearanceSection: some View {
        section(title: tr("Оформление", "Appearance"), hint: nil) {
            VStack(spacing: 8) {
                pickerRow(
                    icon: "paintbrush.fill",
                    title: tr("Тема", "Theme"),
                    subtitle: settings.theme.subtitle,
                    value: settings.theme.title
                ) {
                    ForEach(AppTheme.allCases) { theme in
                        Button {
                            if settings.haptics { jtHaptic() }
                            settings.theme = theme
                        } label: {
                            Label(theme.title, systemImage: theme.icon)
                        }
                    }
                }

                pickerRow(
                    icon: "character.bubble.fill",
                    title: tr("Язык", "Language"),
                    subtitle: tr("Меняется сразу, перезапуск не нужен",
                                 "Applies immediately, no restart needed"),
                    value: "\(settings.language.flag)  \(settings.language.title)"
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Button {
                            if settings.haptics { jtHaptic() }
                            settings.language = language
                        } label: {
                            Text("\(language.flag)  \(language.title)")
                        }
                    }
                }
            }
        }
    }

    /// Строка с выпадающим меню — для настроек, у которых больше двух значений.
    private func pickerRow<Content: View>(icon: String,
                                          title: String,
                                          subtitle: String,
                                          value: String,
                                          @ViewBuilder menu: () -> Content) -> some View {
        Menu {
            menu()
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(JT.accent)
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundColor(JT.text)
                        .font(.system(size: 15, weight: .semibold))
                    Text(subtitle)
                        .foregroundColor(JT.sub)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    Text(value)
                        .foregroundColor(JT.accent)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundColor(JT.sub)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(JT.bg2)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(JT.stroke, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - DNS

    private var dnsSection: some View {
        section(title: tr("DNS-сервер", "DNS server"),
                hint: tr("Через него идут запросы внутри туннеля",
                         "Queries inside the tunnel go through it")) {
            VStack(spacing: 8) {
                ForEach(AppSettings.DNSProvider.allCases) { provider in
                    dnsRow(provider)
                }

                if needsReconnect {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                        Text(tr("Переподключись, чтобы применить",
                                "Reconnect to apply"))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(JT.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }
        }
    }

    private func dnsRow(_ provider: AppSettings.DNSProvider) -> some View {
        let active = settings.dns == provider

        return Button {
            if settings.haptics { jtHaptic() }
            if settings.dns != provider {
                settings.dns = provider
                dnsChanged = true
            }
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(active ? JT.accent : JT.cardHi)
                        .frame(width: 34, height: 34)
                    Image(systemName: provider.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(active ? .white : JT.sub)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title)
                        .foregroundColor(JT.text)
                        .font(.system(size: 15, weight: .semibold))
                    Text(provider.subtitle)
                        .foregroundColor(JT.sub)
                        .font(.system(size: 11))
                }

                Spacer()

                if active {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(JT.green)
                        .font(.system(size: 19))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(active ? JT.cardHi : JT.bg2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(active ? JT.green.opacity(0.35) : JT.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Поведение

    private var behaviourSection: some View {
        section(title: tr("Поведение", "Behaviour"), hint: nil) {
            VStack(spacing: 8) {
                toggleRow(
                    icon: "arrow.clockwise.circle.fill",
                    title: tr("Держать соединение", "Keep connected"),
                    subtitle: tr("Система сама поднимет туннель, если он оборвался или сменилась сеть. Применяется при следующем подключении",
                                 "The system brings the tunnel back up if it drops or the network changes. Takes effect on the next connection"),
                    isOn: $settings.autoConnect
                )

                toggleRow(
                    icon: "bolt.shield.fill",
                    title: "Live Activity",
                    subtitle: tr("Статус соединения на экране блокировки и в Dynamic Island. Появляется при запуске туннеля из приложения",
                                 "Connection status on the Lock Screen and in the Dynamic Island. Appears when the tunnel starts from the app"),
                    isOn: $settings.liveActivity
                )

                toggleRow(
                    icon: "iphone.radiowaves.left.and.right",
                    title: tr("Вибрация", "Haptics"),
                    subtitle: tr("Отклик при нажатии кнопок", "Feedback when you tap buttons"),
                    isOn: $settings.haptics
                )

                // Подробный журнал.
                //
                // Выключен по умолчанию намеренно: на подробном уровне ядро
                // записывает каждое соединение вместе с адресом назначения, то
                // есть историю посещений. Про это сказано прямо в подписи —
                // человек должен понимать, что включает.
                toggleRow(
                    icon: "doc.text.magnifyingglass",
                    title: tr("Подробный журнал ядра", "Verbose core log"),
                    subtitle: tr("Включай только для разбора неполадок: записывает "
                               + "адреса, куда идут соединения. Переподключись после включения",
                                 "Turn on only for troubleshooting: it records the "
                               + "addresses connections go to. Reconnect after enabling"),
                    isOn: $settings.verboseLog
                )
            }
        }
    }

    private func toggleRow(icon: String,
                           title: String,
                           subtitle: String,
                           isOn: Binding<Bool>) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isOn.wrappedValue ? JT.accent : JT.cardHi)
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isOn.wrappedValue ? .white : JT.sub)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundColor(JT.text)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .foregroundColor(JT.sub)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(JT.accent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(JT.bg2)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(JT.stroke, lineWidth: 1))
        )
    }

    // MARK: - О приложении

    private var aboutSection: some View {
        section(title: tr("О приложении", "About"), hint: nil) {
            VStack(spacing: 8) {
                infoRow(title: tr("Версия", "Version"), value: settings.appVersion)

                linkRow(
                    icon: "questionmark.circle.fill",
                    title: tr("Помощь", "Help"),
                    subtitle: tr("Как добавить ключ и что делать при ошибках",
                                 "Adding keys and fixing common errors"),
                    url: "https://zyng.online/support.html"
                )

                linkRow(
                    icon: "hand.raised.fill",
                    title: tr("Политика конфиденциальности", "Privacy policy"),
                    subtitle: tr("Что приложение делает с данными",
                                 "What the app does with your data"),
                    url: "https://zyng.online/privacy.html"
                )

                // Журнал ядра.
                //
                // Нужен ровно в том случае, который иначе не диагностируется:
                // туннель поднялся, а страницы не открываются. Ошибки при этом
                // нет — показывать нечего, — но ядро в такие моменты обычно
                // пишет что-то внятное про сервер или сертификат. Раньше это
                // оседало в файле и никем не читалось.
                Button {
                    coreLog = TunnelDiagnostics.coreLog()
                    showCoreLog = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundColor(JT.accent)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("Журнал ядра", "Core log"))
                                .foregroundColor(JT.text)
                                .font(.system(size: 15, weight: .medium))
                            Text(tr("Что пишет движок — пригодится, если не грузятся страницы",
                                    "What the engine says — useful when pages do not load"))
                                .foregroundColor(JT.sub)
                                .font(.system(size: 11))
                                .lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(JT.sub)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(JT.bg2)
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke(JT.stroke, lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)

                linkRow(
                    icon: "paperplane.fill",
                    title: tr("Канал в Telegram", "Telegram channel"),
                    subtitle: tr("Новости, ключи и помощь", "News, keys and support"),
                    url: "https://t.me/zyngfast"
                )
            }
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(JT.text)
                .font(.system(size: 15, weight: .medium))
            Spacer()
            Text(value)
                .foregroundColor(JT.sub)
                .font(.system(size: 13, design: .monospaced))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(JT.bg2)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(JT.stroke, lineWidth: 1))
        )
    }

    private func linkRow(icon: String,
                         title: String,
                         subtitle: String,
                         url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(JT.accent)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundColor(JT.text)
                        .font(.system(size: 15, weight: .medium))
                    Text(subtitle)
                        .foregroundColor(JT.sub)
                        .font(.system(size: 11))
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .foregroundColor(JT.sub)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(JT.bg2)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(JT.stroke, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Общая обёртка секции

    private func section<Content: View>(title: String,
                                        hint: String?,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .foregroundColor(JT.sub)
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.8)

                if let hint {
                    Text(hint)
                        .foregroundColor(JT.sub.opacity(0.7))
                        .font(.system(size: 11))
                }
            }
            .padding(.leading, 4)

            content()
        }
    }
}
