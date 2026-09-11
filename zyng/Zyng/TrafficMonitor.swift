import Foundation
import Combine

/// Читает статистику трафика и отдаёт её экрану.
///
/// Отдельный объект, а не чтение прямо из тела представления.
///
/// Сначала цифры читались внутри TimelineView — то есть файл открывался,
/// разбирался и закрывался на главном потоке при каждой перерисовке. Секунду
/// это незаметно, но перерисовка случается не только по таймеру: она идёт и
/// на смене состояния, и на каждом кадре пружины. Работа с диском внутри кадра
/// — верный способ получить подёргивание ровно там, где движение должно быть
/// плавным.
///
/// Здесь чтение уходит в фоновую очередь, а на главный поток попадает уже
/// готовое значение.
@MainActor
final class TrafficMonitor: ObservableObject {

    @Published private(set) var stats: TrafficStats = .empty

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }

        task = Task { [weak self] in
            while !Task.isCancelled {
                // Файл пишет расширение раз в секунду — чаще спрашивать нечего.
                let fresh = await Task.detached(priority: .utility) {
                    TrafficStats.load()
                }.value

                guard !Task.isCancelled else { return }
                self?.stats = fresh

                try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        stats = .empty
    }
}
