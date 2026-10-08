import Foundation
import Observation

/// Есть ли сеть — для баннера «No connection». Только отображение:
/// outbox и отправку при появлении сети ведёт `ChatService`.
@MainActor
@Observable
final class ConnectivityStatus {
    private(set) var isOnline: Bool

    @ObservationIgnored private let monitor: any ConnectivityMonitoring

    init(monitor: any ConnectivityMonitoring) {
        self.monitor = monitor
        isOnline = monitor.isOnline
    }

    /// Подписка живёт, пока жива задача вызывающего (`.task` во View).
    func observe() async {
        for await isOnline in monitor.updates() {
            self.isOnline = isOnline
        }
    }
}
