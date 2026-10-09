import Foundation

/// Разрешение на уведомления в системе. Provisional/ephemeral считаем `authorized`.
enum NotificationAuthorization: Sendable, Hashable {
    case notDetermined
    case authorized
    case denied
}

/// Локальное уведомление, готовое к показу.
struct LocalNotification: Sendable, Hashable {
    let title: String
    let body: String
    /// Чат, который откроется по нажатию; `nil` — просто открыть приложение.
    let chatId: UUID?
}

/// Обёртка над `UNUserNotificationCenter` — для тестов и превью.
@MainActor
protocol LocalNotificationScheduling: AnyObject {
    func authorization() async -> NotificationAuthorization
    /// Системный запрос разрешения (показывается только при `notDetermined`).
    /// - Returns: разрешено ли после запроса.
    func requestAuthorization() async -> Bool
    func schedule(_ notification: LocalNotification) async
}

/// Активно ли приложение сейчас (на экране и в фокусе).
@MainActor
protocol AppActivityProviding: AnyObject {
    var isAppActive: Bool { get }
}
