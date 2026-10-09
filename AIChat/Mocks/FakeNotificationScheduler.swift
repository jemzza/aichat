#if DEBUG
import Foundation

/// Уведомления в памяти: разрешение задаёт тест, отправленные копятся в `scheduled`.
@MainActor
final class FakeNotificationScheduler: LocalNotificationScheduling {
    var status: NotificationAuthorization
    /// Что «ответит пользователь» на системный запрос.
    var grantsOnRequest: Bool
    private(set) var requestCount = 0
    private(set) var scheduled: [LocalNotification] = []

    init(status: NotificationAuthorization = .notDetermined, grantsOnRequest: Bool = true) {
        self.status = status
        self.grantsOnRequest = grantsOnRequest
    }

    func authorization() async -> NotificationAuthorization { status }

    func requestAuthorization() async -> Bool {
        requestCount += 1
        if status == .notDetermined { status = grantsOnRequest ? .authorized : .denied }
        return status == .authorized
    }

    func schedule(_ notification: LocalNotification) async {
        scheduled.append(notification)
    }
}

/// Активность приложения под контролем теста.
@MainActor
final class FakeAppActivity: AppActivityProviding {
    var isAppActive: Bool

    init(isAppActive: Bool = false) {
        self.isAppActive = isAppActive
    }
}
#endif
