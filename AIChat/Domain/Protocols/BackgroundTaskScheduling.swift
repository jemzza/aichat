import Foundation

/// Фоновое время на генерацию ответа (`UIApplication.beginBackgroundTask`).
/// Протокол — чтобы `ChatService` не зависел от UIKit и проверялся в тестах.
@MainActor
protocol BackgroundTaskScheduling: AnyObject {
    /// - Parameter expiration: система забирает время — генерацию надо прервать.
    /// - Returns: токен для `endTask`.
    func beginTask(expiration: @escaping @MainActor () -> Void) -> Int
    func endTask(_ token: Int)
}
