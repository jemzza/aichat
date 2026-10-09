import UIKit
import UserNotifications

/// Делегат уведомлений. Назначается в `didFinishLaunching` — иначе нажатие на уведомление,
/// которое запустило приложение с нуля, потеряется.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let navigation = ChatNavigationRequests()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// На переднем плане уведомления не показываем (их и не шлём, см. `NotificationPolicy`).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    /// Нажатие на уведомление о готовом ответе — открыть этот чат.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let chatId = UserNotificationScheduler.chatId(from: response.notification.request.content.userInfo)
        else { return }
        await MainActor.run { navigation.requestOpenChat(id: chatId) }
    }
}
