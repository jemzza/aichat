import Foundation

protocol ConnectivityMonitoring: Sendable {
    var isOnline: Bool { get }

    /// Текущее значение сразу, дальше — только изменения, без повторов.
    /// Каждый вызов создаёт отдельный поток: подписчиков может быть несколько.
    func updates() -> AsyncStream<Bool>
}
