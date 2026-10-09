import Foundation
import UserNotifications

/// `LocalNotificationScheduling` на `UNUserNotificationCenter`.
@MainActor
final class UserNotificationScheduler: LocalNotificationScheduling {
    /// Ключ `userInfo` с id чата — его читает делегат при нажатии.
    nonisolated static let chatIdKey = "chatId"

    private var center: UNUserNotificationCenter { .current() }

    func authorization() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func schedule(_ notification: LocalNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        if let chatId = notification.chatId {
            content.userInfo = [Self.chatIdKey: chatId.uuidString]
            content.threadIdentifier = chatId.uuidString
        }
        // `trigger: nil` — показать сразу.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    /// Id чата из `userInfo` уведомления; `nil` — уведомление не про чат.
    nonisolated static func chatId(from userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[chatIdKey] as? String).flatMap(UUID.init(uuidString:))
    }
}
