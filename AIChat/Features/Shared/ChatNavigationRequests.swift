import Foundation
import Observation

/// Просьба открыть чат извне экранов — нажатие на уведомление. Пишет `AppDelegate`,
/// выполняет `RootView`. На холодном старте просьба ждёт, пока откроется база и
/// появится `RootView`.
@MainActor
@Observable
final class ChatNavigationRequests {
    private(set) var pendingChatId: UUID?

    func requestOpenChat(id: UUID) {
        pendingChatId = id
    }

    /// Забирает просьбу (один раз).
    func takePendingChatId() -> UUID? {
        defer { pendingChatId = nil }
        return pendingChatId
    }
}
