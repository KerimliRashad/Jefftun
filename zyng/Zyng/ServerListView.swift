import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Экран выбора сервера.
///
/// Каждая подписка — своя вкладка со своим именем, трафиком и списком серверов.
/// Последняя вкладка — ключи, добавленные вручную.
@MainActor
struct ServerListView: View {

    @ObservedObject var store: ServerStore
    @ObservedObject private var probe = LatencyProbe.shared
    /// Нужен ради темы и языка: без подписки на настройки экран не
    /// перерисовывался бы при их смене и оставался в прежнем оформлении.
    @ObservedObject private var settings = AppSettings.shared

    let onPicked: () -> Void
    let onAdd: () -> Void

    /// Вкладка — либо конкретная подписка, либо раздел одиночных ключей.
    private enum Tab: Hashable {
        case subscription(UUID)
        case singles
    }

    @State private var tab: Tab?

    /// Сортировать ли список по задержке. Переключается кнопкой в шапке.
    @AppStorage("servers_sort_by_latency") private var sortByLatency = true

    var body: some View {
        ZStack {
            JT.backdrop.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                tabBar

                ScrollView {
                    VStack(spacing: 10) {
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
            }
        }
        .task {
            selectTabIfNeeded()
            await store.refreshStale()
            selectTabIfNeeded()
            // Замер сам, без нажатия на секундомер: список без задержек
            // бесполезен, а вручную его запускал не каждый.
            await probe.measure(visibleServers)
        }
        .onChange(of: tab) { _, _ in
            // У соседней вкладки своя подписка и свои серверы — их ещё не мерили.
            Task { await probe.measure(visibleServers) }
        }
    }

    /// При первом показе и после удаления подписки вкладка может исчезнуть.
    private func selectTabIfNeeded() {
        let available = tabs
        if tab == nil || !available.contains(where: { $0 == tab }) {
            tab = available.first
        }
    }

    private var tabs: [Tab] {
        store.subscriptions.map { .subscription($0.id) } + [.singles]
    }

    private var currentSubscription: Subscription? {
        guard case .subscription(let id) = tab else { return nil }
        return store.subscriptions.first { $0.id == id }
    }

    /// Ключ самого быстрого из измеренных на текущей вкладке.
    ///
    /// Отмечаем его в списке: когда серверов больше десятка, глазами искать
    /// наименьшее число утомительно, а выбирают почти всегда именно его.
    private var fastestRaw: String? {
        let measured = visibleServers.compactMap { server -> (String, Int)? in
            guard case .ms(let value)? = probe.latency(for: server) else { return nil }
            return (server.raw, value)
        }
        return measured.min { $0.1 < $1.1 }?.0
    }

    /// Раскладывает серверы: быстрые сверху, ещё не измеренные — следом,
    /// не ответившие — в конце. Пока ничего не измерено, порядок исходный.
    private func sorted(_ servers: [Server]) -> [Server] {
        guard sortByLatency else { return servers }

        // Здесь именно Latency?, а не Latency: «ещё не мерили» — это nil.
        // Разворачиваем явно, иначе случаи пришлось бы писать через `?`,
        // а `.none` читалось бы как случай самого Latency, которого там нет.
        func rank(_ server: Server) -> (Int, Int) {
            guard let state = probe.latency(for: server) else { return (1, 0) }
            switch state {
            case .ms(let value):  return (0, value)
            case .measuring:      return (1, 0)
            case .failed:         return (2, 0)
            }
        }
        return servers.enumerated()
            .sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                // При равном ранге сохраняем исходный порядок: список не должен
                // перетасовываться сам по себе между обновлениями.
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
    }

    /// Серверы текущей вкладки — их и меряет кнопка замера.
    private var visibleServers: [Server] {
        let all = currentSubscription.map { store.servers(in: $0) } ?? store.singleServers
        // Мерим только то, что имеет смысл мерить: неподдерживаемые всё равно
        // не подключатся, а протоколы поверх UDP не отвечают на TCP-проверку.
        return all.filter { $0.isSupported && !$0.usesDatagrams }
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(spacing: 10) {
            Text(tr("Серверы", "Servers"))
                .foregroundColor(JT.text)
                .font(.system(size: 20, weight: .bold))

            Spacer()

            Button {
                jtHaptic()
                // Нажали сами — значит, хотят пересчитать всё, включая те
                // серверы, что в прошлый раз не ответили.
                Task { await probe.measure(visibleServers, force: true) }
            } label: {
                Group {
                    if probe.isRunning {
                        ProgressView().tint(JT.accent)
                    } else {
                        Image(systemName: "speedometer")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .foregroundColor(JT.accent)
                .frame(width: 32, height: 32)
            }
            .disabled(probe.isRunning || visibleServers.isEmpty)

            Button {
                jtHaptic()
                withAnimation(.easeOut(duration: 0.25)) { sortByLatency.toggle() }
            } label: {
                Image(systemName: sortByLatency
                      ? "arrow.up.arrow.down.circle.fill"
                      : "arrow.up.arrow.down.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(sortByLatency ? JT.accent : JT.sub)
                    .frame(width: 32, height: 32)
            }

            Button { onAdd() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(JT.accent)
                    .frame(width: 32, height: 32)
            }

            Button { onPicked() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(JT.sub)
                    .font(.system(size: 24))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Полоса вкладок

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.subscriptions) { sub in
                    tabChip(
                        title: sub.name,
                        // Считаем видимое. Раньше здесь стояло число всех ключей,
                        // и вкладка обещала восемь серверов, а в списке было шесть.
                        count: store.servers(in: sub).filter(\.isSupported).count,
                        tab: .subscription(sub.id)
                    )
                }

                tabChip(
                    title: tr("Ключи", "Keys"),
                    count: store.singleServers.filter(\.isSupported).count,
                    tab: .singles
                )
            }
            .padding(.horizontal, 16)
        }
    }

    private func tabChip(title: String, count: Int, tab item: Tab) -> some View {
        let active = tab == item

        return Button {
            withAnimation(.easeOut(duration: 0.15)) { tab = item }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(active ? .white.opacity(0.75) : JT.sub)
            }
            .foregroundColor(active ? .white : JT.sub)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(active ? JT.accent : JT.card)
                    .overlay(Capsule().stroke(active ? .clear : JT.stroke, lineWidth: 1))
            )
        }
    }

    // MARK: - Содержимое вкладки

    @ViewBuilder
    private var content: some View {
        if let sub = currentSubscription {
            subscriptionHeader(sub)

            let all = store.servers(in: sub)
            let servers = all.filter(\.isSupported)
            let hidden = all.count - servers.count

            if all.isEmpty {
                emptyState(
                    icon: "arrow.triangle.2.circlepath",
                    title: tr("Подписка пустая", "Subscription is empty"),
                    hint: tr("Обнови её — возможно, панель ещё не отдала серверы",
                             "Refresh it — the provider may not have sent servers yet")
                )
            } else if servers.isEmpty {
                emptyState(
                    icon: "questionmark.circle",
                    title: tr("Здесь нечего выбрать", "Nothing to pick here"),
                    hint: tr("Все серверы этой подписки используют транспорт, "
                           + "которого нет в ядре Zyng. Загляни в соседнюю вкладку",
                             "Every server in this subscription uses a transport "
                           + "the Zyng core does not have. Try another tab")
                )
            } else {
                deadSubscriptionNote(servers)
                ForEach(sorted(servers)) { server in
                    serverRow(server, showDelete: false)
                }
                hiddenNote(hidden)
            }
        } else if store.subscriptions.isEmpty && store.singleServers.isEmpty {
            emptyState(
                icon: "server.rack",
                title: tr("Серверов пока нет", "No servers yet"),
                hint: tr("Добавь ссылку-подписку или отдельный ключ",
                         "Add a subscription link or a single key")
            )
        } else if store.singleServers.isEmpty {
            emptyState(
                icon: "key",
                title: tr("Отдельных ключей нет", "No single keys"),
                hint: tr("Вставь ключ vless:// или другой", "Paste a vless:// key or another")
            )
        } else {
            ForEach(sorted(store.singleServers.filter(\.isSupported))) { server in
                serverRow(server, showDelete: true)
            }
            hiddenNote(store.singleServers.filter { !$0.isSupported }.count)
        }
    }

    // MARK: - Карточка подписки

    private func subscriptionHeader(_ sub: Subscription) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sub.name)
                        .foregroundColor(JT.text)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(1)

                    Text(subtitle(for: sub))
                        .foregroundColor(JT.sub)
                        .font(.system(size: 11))
                }

                Spacer()

                Button {
                    jtHaptic()
                    Task { await store.refresh(sub.id) }
                } label: {
                    Group {
                        if store.refreshing.contains(sub.id) {
                            ProgressView().tint(JT.accent)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .foregroundColor(JT.accent)
                    .frame(width: 30, height: 30)
                }

                Menu {
                    if let page = sub.webPage, let url = URL(string: page) {
                        Link(destination: url) {
                            Label(tr("Личный кабинет", "Provider page"), systemImage: "safari")
                        }
                    }
                    Button(role: .destructive) {
                        store.removeSubscription(sub.id)
                        selectTabIfNeeded()
                    } label: {
                        Label(tr("Удалить подписку", "Remove subscription"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(JT.sub)
                        .frame(width: 30, height: 30)
                }
            }

            trafficBar(sub)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(JT.card)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(JT.stroke, lineWidth: 1))
        )
    }

    /// Полоса расхода трафика. Для безлимита полосы нет — только цифра.
    private func trafficBar(_ sub: Subscription) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(trafficText(sub))
                    .foregroundColor(JT.text)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))

                Spacer()

                if let expires = sub.expiresAt {
                    Text(expiryText(expires))
                        .foregroundColor(expires < Date() ? JT.red : JT.sub)
                        .font(.system(size: 11, weight: .medium))
                }
            }

            if !sub.isUnlimited {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(JT.bg1)
                        Capsule()
                            .fill(sub.usedFraction > 0.9 ? JT.red : JT.accent)
                            .frame(width: max(4, geo.size.width * sub.usedFraction))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 2)
    }

    private func trafficText(_ sub: Subscription) -> String {
        sub.isUnlimited
            ? "\(formatBytes(sub.usedTraffic)) / ∞"
            : "\(formatBytes(sub.usedTraffic)) / \(formatBytes(sub.totalTraffic))"
    }

    private func expiryText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"

        let stamp = formatter.string(from: date)
        guard date > Date() else { return tr("истекла \(stamp)", "expired \(stamp)") }

        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        return days <= 30
            ? tr("осталось \(days) дн.", "\(days) days left")
            : tr("до \(stamp)", "until \(stamp)")
    }

    private func subtitle(for sub: Subscription) -> String {
        var parts: [String] = []

        if let updated = sub.updatedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "dd.MM HH:mm"
            parts.append(formatter.string(from: updated))
        } else {
            parts.append(tr("не обновлялась", "never refreshed"))
        }

        parts.append(tr("автообновление — \(sub.autoUpdateHours) ч.",
                        "auto-refresh every \(sub.autoUpdateHours) h"))
        return parts.joined(separator: " • ")
    }

    /// Сколько серверов скрыто и почему.
    ///
    /// Раньше такие серверы показывались помеченными, и нажатие на них
    /// открывало окно с объяснением. Выбрать их всё равно было нельзя, так что
    /// окно только мешало. Теперь их просто нет в списке, а короткая строка
    /// внизу объясняет, почему серверов меньше, чем обещает вкладка.
    @ViewBuilder
    private func hiddenNote(_ count: Int) -> some View {
        if count > 0 {
            Text(tr("Скрыто серверов: \(count) — их транспорт не поддерживается",
                    "\(count) server(s) hidden — their transport is unsupported"))
                .font(.system(size: 11))
                .foregroundColor(JT.sub.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        }
    }

    // MARK: - Строка сервера

    private func serverRow(_ server: Server, showDelete: Bool) -> some View {
        let isSelected = server.raw == store.selectedRaw

        return HStack(spacing: 12) {
            Text(server.flag)
                .font(.system(size: 20))
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(JT.bg2)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .foregroundColor(JT.text)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text("\(server.proto) · \(server.transport)")
                        .foregroundColor(JT.sub)
                        .font(.system(size: 11))

                    // Самый быстрый из измеренных. Когда серверов больше
                    // десятка, глазами искать наименьшее число утомительно,
                    // а выбирают почти всегда именно его.
                    if server.raw == fastestRaw {
                        HStack(spacing: 2) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text(tr("быстрее всех", "fastest"))
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(JT.green)
                    }
                }
            }

            Spacer(minLength: 8)

            if !server.usesDatagrams {
                latencyLabel(for: server)
            } else if server.usesDatagrams {
                // Замерить нельзя, но сервер рабочий — так и пишем, вместо
                // прочерка, который читается как «не отвечает».
                badge(text: "UDP", color: JT.sub)
            }

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(JT.green)
                    .font(.system(size: 18))
            }

            if showDelete {
                Button {
                    store.removeSingleKey(server.raw)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(JT.red.opacity(0.8))
                        .font(.system(size: 14))
                }
            }
        }
        .padding(12)
        // Выбранную строку обводим зелёным — это её единственное отличие,
        // и оно должно читаться с одного взгляда. Остальные берут общий вид
        // карточки: блик сверху, мягкая тень, одинаковый радиус.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? JT.cardHi : JT.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? AnyShapeStyle(JT.green.opacity(0.45))
                        : AnyShapeStyle(LinearGradient(
                            colors: [JT.text.opacity(0.08), JT.stroke.opacity(0.5)],
                            startPoint: .top, endPoint: .bottom)),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture {
            jtHaptic()
            store.select(server)
            onPicked()
        }
        // Долгое нажатие — адрес и сама ссылка.
        //
        // Когда сервер молчит, первый вопрос всегда один: куда мы вообще
        // стучимся. Раньше узнать это можно было только из журнала ядра, да и
        // то если туннель успел подняться. Здесь адрес виден сразу, а ссылку
        // можно скопировать и сравнить с другим клиентом.
        .contextMenu {
            if let endpoint = try? SingBoxConfig.serverEndpoint(from: server.raw) {
                Text("\(endpoint.host):\(endpoint.port)")
            }
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = server.raw
                #endif
                jtHaptic()
            } label: {
                Label(tr("Скопировать ссылку", "Copy link"), systemImage: "doc.on.doc")
            }
        }
    }

    /// Предупреждение, когда не отвечает НИ ОДИН сервер подписки.
    ///
    /// Один молчащий сервер — обычное дело: выключили, перегружают. Но когда
    /// молчат все до единого, причина почти всегда одна: ссылка подписки
    /// устарела. Провайдер перевёл людей на новые адреса, а по старой ссылке
    /// продолжает отдаваться прежний список — он загружается, обновляется,
    /// выглядит живым, и понять, что серверов за ним уже нет, неоткуда.
    ///
    /// Именно на этом мы потеряли несколько дней: приложение исправно
    /// подключалось к серверам, которых больше не существует.
    @ViewBuilder
    private func deadSubscriptionNote(_ servers: [Server]) -> some View {
        let measured = servers.compactMap { probe.latency(for: $0) }
        let failed = measured.filter { if case .failed = $0 { return true } else { return false } }

        // Только когда измерены все и не ответил никто.
        if measured.count == servers.count, failed.count == servers.count, servers.count > 1 {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(JT.red)

                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Не отвечает ни один сервер этой подписки",
                            "No server in this subscription responds"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(JT.text)

                    Text(tr("Скорее всего ссылка подписки устарела: провайдер перевёл "
                          + "серверы на новые адреса. Возьми у него свежую ссылку и "
                          + "добавь заново, а эту удали.",
                            "The subscription link is most likely stale: the provider "
                          + "moved the servers. Get a fresh link and add it, then "
                          + "delete this one."))
                        .font(.system(size: 12))
                        .foregroundColor(JT.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(JT.red.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(JT.red.opacity(0.28), lineWidth: 1))
            )
        }
    }

    /// Ещё не мерили — пусто. Меряется — крутилка. Дальше результат.
    @ViewBuilder
    private func latencyLabel(for server: Server) -> some View {
        if let state = probe.latency(for: server) {
            switch state {
            case .measuring:
                ProgressView()
                    .controlSize(.mini)
                    .tint(JT.sub)
            case .ms(let ms):
                badge(text: "\(ms) \(tr("мс", "ms"))",
                      color: color(forLatency: ms),
                      monospaced: true)
            case .failed:
                badge(text: tr("нет ответа", "no response"), color: JT.red)
            }
        }
    }

    /// Значок справа в строке — одинаковый для задержки, UDP и отказа.
    private func badge(text: String, color: Color, monospaced: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11,
                          weight: .semibold,
                          design: monospaced ? .monospaced : .default))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color.opacity(0.14))
                    .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 1))
            )
    }

    private func color(forLatency ms: Int) -> Color {
        switch ms {
        case ..<100:  return JT.green
        case ..<250:  return JT.accent
        default:      return JT.red
        }
    }

    // MARK: - Пустое состояние

    private func emptyState(icon: String, title: String, hint: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundColor(JT.sub.opacity(0.7))
            Text(title)
                .foregroundColor(JT.text)
                .font(.system(size: 15, weight: .semibold))
            Text(hint)
                .foregroundColor(JT.sub)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
            Button(tr("Добавить", "Add")) { onAdd() }
                .foregroundColor(JT.accent)
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}
