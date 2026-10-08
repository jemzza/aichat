import Foundation

/// Как показать ошибку ответа: текст и иконка по `ErrorKind` (таблица в docs/task.md).
/// Тексты не содержат ключ, URL и сырой ответ сервера — только понятная причина.
struct MessageErrorPresentation: Sendable {
    let title: LocalizedStringResource
    let systemImage: String

    init(kind: ErrorKind) {
        switch kind {
        case .offline:
            title = "No internet connection."
            systemImage = "wifi.slash"
        case .rateLimited:
            title = "The AI service rate limit was reached."
            systemImage = "hourglass"
        case .unauthorized:
            title = "The AI service rejected the API key."
            systemImage = "key"
        case .forbidden:
            title = "The AI service isn't available in your region."
            systemImage = "globe"
        case .server:
            title = "The AI service is having problems. Please try again."
            systemImage = "exclamationmark.icloud"
        case .unsupportedLanguage:
            title = "The on-device model doesn't support this language."
            systemImage = "character.bubble"
        case .unknown:
            title = "Something went wrong."
            systemImage = "exclamationmark.triangle"
        }
    }

    /// Ответ оборвался: приложение закрылось во время генерации.
    static let interrupted = MessageErrorPresentation(
        title: "The response was interrupted.",
        systemImage: "exclamationmark.bubble"
    )

    private init(title: LocalizedStringResource, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    /// Плашка для ответа ассистента, если она нужна (`failed` или `interrupted`).
    static func forMessage(_ message: Message) -> MessageErrorPresentation? {
        guard message.role == .assistant else { return nil }
        switch message.status {
        case .failed: return MessageErrorPresentation(kind: message.failure?.kind ?? .unknown)
        case .interrupted: return .interrupted
        case .pending, .sent, .streaming, .done, .cancelled: return nil
        }
    }

    /// Сколько целых секунд ждать до повтора (429 с `retry-after`); `nil` — можно сейчас.
    static func secondsUntilRetry(_ failure: MessageFailure?, now: Date) -> Int? {
        guard let retryAt = failure?.retryAt else { return nil }
        let remaining = retryAt.timeIntervalSince(now)
        return remaining > 0 ? Int(remaining.rounded(.up)) : nil
    }
}
