#if DEBUG
import Foundation
import Synchronization

/// Сеть, которой управляют вручную: `setOnline(_:)`.
final class FakeConnectivityMonitor: ConnectivityMonitoring {
    private struct State {
        var isOnline: Bool
        var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(isOnline: Bool = true) {
        state = Mutex(State(isOnline: isOnline))
    }

    var isOnline: Bool { state.withLock(\.isOnline) }

    func setOnline(_ isOnline: Bool) {
        state.withLock { state in
            guard state.isOnline != isOnline else { return }
            state.isOnline = isOnline
            for continuation in state.observers.values { continuation.yield(isOnline) }
        }
    }

    func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
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
}
#endif
