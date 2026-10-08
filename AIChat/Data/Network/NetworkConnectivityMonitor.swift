import Foundation
import Network
import Synchronization

/// Статус сети на `NWPathMonitor`. Один монитор на приложение; подписчиков может быть
/// несколько — каждый получает текущее значение сразу, дальше только изменения.
///
/// На симуляторе `NWPathMonitor` ненадёжен — сценарии без сети проверяем `-mockOffline`.
final class NetworkConnectivityMonitor: ConnectivityMonitoring {
    private struct State {
        /// До первого ответа монитора считаем, что сеть есть: лучше попытаться
        /// отправить и получить `offline`, чем зря положить сообщение в outbox.
        var isOnline = true
        var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let monitor = NWPathMonitor()
    private let state = Mutex(State())

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(isOnline: path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "NetworkConnectivityMonitor"))
    }

    deinit {
        monitor.cancel()
    }

    var isOnline: Bool { state.withLock(\.isOnline) }

    func updates() -> AsyncStream<Bool> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            state.withLock { state in
                state.observers[id] = continuation
                continuation.yield(state.isOnline)
            }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
            }
        }
    }

    private func update(isOnline: Bool) {
        state.withLock { state in
            guard state.isOnline != isOnline else { return }
            state.isOnline = isOnline
            for continuation in state.observers.values { continuation.yield(isOnline) }
        }
    }
}
