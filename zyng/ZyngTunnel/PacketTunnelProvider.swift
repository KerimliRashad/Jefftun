import NetworkExtension
import Foundation
import Libcore

/// Packet tunnel расширение Zyng.
///
/// Пакетами занимается ядро sing-box: мы отдаём ему конфиг и файловый дескриптор
/// туннеля, дальше оно само держит TCP/IP-стек, маршрутизацию и шифрование.
/// Своего цикла чтения пакетов здесь нет и быть не должно — он бы дублировал
/// работу ядра и упирался в лимит памяти расширения.
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandServer: LibboxCommandServer?
    private var platform: PlatformInterface?
    /// Поднимали ли мы второе ядро — чтобы знать, кого гасить при остановке.
    private var usesXray = false

    // MARK: - Запуск

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        // Запуск уходит в фон: дальше мы ждём, пока ядро откроет туннель,
        // а блокировать поток, на котором система вызвала startTunnel, нельзя.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.start(completionHandler: completionHandler)
        }
    }

    private func start(completionHandler: @escaping (Error?) -> Void) {
        NSLog("🔵 Zyng: startTunnel, ядро \(LibboxVersion())")

        // Причину прошлой неудачи убираем сразу: иначе после успешного
        // подключения приложение покажет устаревшую ошибку.
        TunnelDiagnostics.clear()
        TunnelDiagnostics.clearTrace()
        TunnelDiagnostics.note("запуск расширения")

        do {
            let key = try readKey()

            // Схему логируем, содержимое ключа — нет: там пароли и UUID.
            NSLog("🔵 Zyng: протокол \(key.prefix(while: { $0 != ":" }))")

            let verbose = readFlag("verbose")
            if verbose { NSLog("🟣 Zyng: подробный журнал ядра включён") }
            let config = try SingBoxConfig.makeConfig(from: key,
                                                     dns: readDNS(),
                                                     verbose: verbose)
            TunnelDiagnostics.note("конфиг собран, протокол \(key.prefix(while: { $0 != ":" }))")

            // Ядро Xray поднимаем ПЕРВЫМ.
            //
            // Для ключей с xhttp конфиг sing-box уже указывает на локальный
            // SOCKS, и если Xray там ещё не слушает, sing-box откроет туннель
            // в никуда: соединение считается установленным, а трафик молча
            // пропадает. Порядок здесь существенный.
            if SingBoxConfig.needsXray(key) {
                NSLog("🔵 Zyng: транспорт требует Xray, поднимаю второе ядро")
                try XrayBridge.start(link: key)
                usesXray = true
                NSLog("✅ Zyng: Xray \(XrayBridge.version) слушает 127.0.0.1:\(XrayBridge.socksPort)")
            }

            try setupCore()
            TunnelDiagnostics.note("рабочие папки и журнал готовы")

            // Проверяем конфиг до запуска: иначе ошибка всплыла бы уже внутри
            // ядра, а туннель просто завис бы в состоянии «подключение».
            var checkError: NSError?
            guard LibboxCheckConfig(config, &checkError) else {
                throw checkError ?? Self.coreError("Конфигурация отвергнута ядром")
            }

            // Адреса сервера считаем ДО поднятия туннеля: сейчас резолвер
            // работает через обычную сеть, а после — уже через туннель,
            // которого без сервера нет.
            let (v4, v6) = Self.resolveServer(of: key)
            let platform = PlatformInterface(provider: self, bypassIPv4: v4, bypassIPv6: v6)
            self.platform = platform

            var serverError: NSError?
            guard let server = LibboxNewCommandServer(
                CommandHandler(provider: self), platform, &serverError
            ) else {
                throw serverError ?? Self.coreError("Не удалось создать сервис ядра")
            }
            self.commandServer = server
            TunnelDiagnostics.note("сервис ядра создан")

            try server.start()
            try server.startOrReloadService(config, options: LibboxOverrideOptions())
            TunnelDiagnostics.note("ядро запущено, жду открытия туннеля")

            NSLog("✅ Zyng: ядро запущено, жду открытия туннеля…")

            // Пока ядро не вызовет openTun, сетевые настройки не применены,
            // и система будет вечно держать статус «подключение». Сообщать
            // об успехе раньше этого момента нельзя.
            guard platform.waitUntilTunnelOpened(timeout: 20) else {
                throw Self.coreError(
                    "Ядро запустилось, но не открыло туннель за 20 секунд. "
                    + "Обычно это значит, что не удалось соединиться с сервером."
                )
            }

            TunnelDiagnostics.note("туннель открыт — соединение установлено")
            NSLog("✅ Zyng: подключение установлено")
            completionHandler(nil)

        } catch {
            // Если Xray успел подняться, а дальше что-то не сложилось, его
            // нужно погасить: иначе он останется слушать порт, и следующая
            // попытка подключения упрётся в занятый адрес.
            if usesXray {
                XrayBridge.stop()
                usesXray = false
            }
            NSLog("❌ Zyng: запуск не удался: \(error.localizedDescription)")
            // Приложение прочитает это и покажет на экране: своих логов
            // расширения оно не видит.
            TunnelDiagnostics.note("ОШИБКА: \(error.localizedDescription)")
            TunnelDiagnostics.record(error.localizedDescription)
            completionHandler(error)
        }
    }

    /// Ядро возвращает false без заполненной ошибки не должно, но полагаться
    /// на это нельзя — иначе получим падение вместо сообщения.
    private static func coreError(_ message: String) -> NSError {
        NSError(domain: "ZyngTunnel", code: 3,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Адреса VPN-сервера, которые нужно вывести из туннеля.
    ///
    /// Возвращает списки IPv4 и IPv6. Если разобрать ключ или разрешить имя
    /// не удалось — пустые списки: тогда всё работает как раньше, без
    /// исключений в маршрутах, и запуск из-за этого не срывается.
    private static func resolveServer(of key: String) -> ([String], [String]) {
        guard let endpoint = try? SingBoxConfig.serverEndpoint(from: key) else {
            TunnelDiagnostics.note("адрес сервера определить не удалось — маршрут не исключаю")
            return ([], [])
        }

        var v4: [String] = []
        var v6: [String] = []

        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var head: UnsafeMutablePointer<addrinfo>?

        // Числовой адрес getaddrinfo вернёт как есть, без обращения к DNS.
        if getaddrinfo(endpoint.host, nil, &hints, &head) == 0, let first = head {
            defer { freeaddrinfo(head) }

            for ptr in sequence(first: first, next: { $0.pointee.ai_next }) {
                guard let addr = ptr.pointee.ai_addr else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(addr, ptr.pointee.ai_addrlen, &host, socklen_t(host.count),
                                  nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let text = String(cString: host)
                if ptr.pointee.ai_family == AF_INET {
                    if !v4.contains(text) { v4.append(text) }
                } else if ptr.pointee.ai_family == AF_INET6 {
                    // Зону вида fe80::1%en0 маршрут не принимает.
                    let clean = text.components(separatedBy: "%").first ?? text
                    if !v6.contains(clean) { v6.append(clean) }
                }
            }
        }

        if v4.isEmpty && v6.isEmpty {
            TunnelDiagnostics.note("имя \(endpoint.host) не разрешилось — маршрут не исключаю")
        } else {
            TunnelDiagnostics.note("адрес сервера исключён из туннеля: \((v4 + v6).joined(separator: ", "))")
        }

        return (v4, v6)
    }

    /// Ключ приезжает из приложения через providerConfiguration.
    private func readKey() throws -> String {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let key = proto.providerConfiguration?["key"] as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "ZyngTunnel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "В конфигурации нет ключа сервера"])
        }
        return key
    }

    /// Флаг из настроек приложения. Приезжает вместе с ключом.
    private func readFlag(_ name: String) -> Bool {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return (proto.providerConfiguration?[name] as? String) == "1"
    }

    /// DNS-сервер, выбранный в настройках. Приезжает вместе с ключом.
    private func readDNS() -> String {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let dns = proto.providerConfiguration?["dns"] as? String,
              !dns.isEmpty else {
            return "1.1.1.1"
        }
        return dns
    }

    /// Ядру нужны рабочие папки. Держим их в App Group, чтобы приложение могло
    /// читать оттуда логи и статистику.
    private func setupCore() throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.online.zyng.Zyng"
        ) else {
            throw NSError(domain: "ZyngTunnel", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Нет доступа к App Group group.online.zyng.Zyng"])
        }

        let base = container.appendingPathComponent("core", isDirectory: true)
        let work = base.appendingPathComponent("work", isDirectory: true)
        let temp = base.appendingPathComponent("temp", isDirectory: true)

        for dir in [base, work, temp] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Ядро написано на Go: при панике процесс умирает мгновенно и ничего
        // сообщить через NetworkExtension не успевает — приложение видит просто
        // «отключено». Поэтому весь его вывод уводим в файл, который переживёт
        // смерть процесса и который прочитает приложение.
        if let stderrPath = TunnelDiagnostics.stderrPath {
            var redirectError: NSError?
            if !LibboxRedirectStderr(stderrPath, &redirectError) {
                NSLog("⚠️ Zyng: не удалось перенаправить вывод ядра: \(redirectError?.localizedDescription ?? "")")
            }
        }

        let options = LibboxSetupOptions()
        options.basePath = base.path
        options.workingPath = work.path
        options.tempPath = temp.path
        options.logMaxLines = 200

        // Libbox* — это функции, а не методы объектов, поэтому Swift не
        // превращает их NSError** в throws: указатель передаём сами.
        var setupError: NSError?
        guard LibboxSetup(options, &setupError) else {
            throw setupError ?? Self.coreError("Не удалось инициализировать ядро")
        }

        // У packet tunnel расширения жёсткий лимит памяти (около 50 МБ).
        // Без этого ядро считает, что памяти сколько угодно, и его убивает
        // система — тот самый SIGKILL.
        LibboxSetMemoryLimit(true)
    }

    // MARK: - Остановка

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        NSLog("🛑 Zyng: stopTunnel, причина \(reason.rawValue)")

        if let commandServer {
            try? commandServer.closeService()
            commandServer.close()
        }
        commandServer = nil
        platform = nil

        if usesXray {
            XrayBridge.stop()
            usesXray = false
        }

        completionHandler()
    }

    // MARK: - Сон и пробуждение
    //
    // Без этого ядро продолжает держать соединения в фоне и тратит батарею,
    // а после пробуждения работает по устаревшему состоянию сети.

    override func sleep(completionHandler: @escaping () -> Void) {
        commandServer?.pause()
        completionHandler()
    }

    override func wake() {
        commandServer?.wake()
    }
}

// MARK: - Обработчик команд от приложения

/// Через этот канал приложение может перезапустить или остановить ядро,
/// а также получать логи и статистику трафика.
private final class CommandHandler: NSObject, LibboxCommandServerHandlerProtocol {

    private weak var provider: PacketTunnelProvider?

    init(provider: PacketTunnelProvider) {
        self.provider = provider
        super.init()
    }

    func serviceReload() throws {
        // Перезапуск с новым конфигом делается пересозданием туннеля из
        // приложения, поэтому здесь работы нет.
    }

    func serviceStop() throws {
        provider?.cancelTunnelWithError(nil)
    }

    /// Системный прокси — понятие из macOS, на iOS его нет.
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        status.available = false
        status.enabled = false
        return status
    }

    func setSystemProxyEnabled(_ enabled: Bool) throws {}

    /// Сюда ядро отдаёт СВОЙ журнал.
    ///
    /// Это и была причина, по которой «журнал ядра» в приложении оставался
    /// пустым, сколько бы мы ни повышали уровень подробности. sing-box пишет
    /// не в файл: он зовёт этот обработчик. А тот отправлял всё в NSLog —
    /// то есть в консоль расширения, которую не видно ни в Xcode, ни где-либо
    /// ещё, потому что отладчик подключён к приложению, а не к расширению.
    ///
    /// Теперь строки идут в общий дневник, и приложение их показывает.
    func writeDebugMessage(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        TunnelDiagnostics.note("ядро: \(message)")
        NSLog("🟣 Zyng core: \(message)")
    }
}
