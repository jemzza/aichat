import UIKit

/// `BackgroundTaskScheduling` на `UIApplication.beginBackgroundTask`: генерация ответа
/// не обрывается сразу при сворачивании приложения.
@MainActor
final class UIKitBackgroundTasks: BackgroundTaskScheduling {
    func beginTask(expiration: @escaping @MainActor () -> Void) -> Int {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "Reply generation") {
            // Обработчик истечения UIKit вызывает на главном потоке. `ChatService` отменяет
            // генерацию, пишет `interrupted` и сам закрывает задачу через `endTask`.
            MainActor.assumeIsolated { expiration() }
        }
        return identifier.rawValue
    }

    func endTask(_ token: Int) {
        let identifier = UIBackgroundTaskIdentifier(rawValue: token)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
