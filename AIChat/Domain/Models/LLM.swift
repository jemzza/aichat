import Foundation

enum LLMRole: String, Hashable, Sendable {
    case system
    case user
    case assistant
}

struct LLMMessage: Hashable, Sendable {
    let role: LLMRole
    let content: String
    /// JPEG-фото к сообщению пользователя (vision-запрос).
    let images: [Data]

    init(role: LLMRole, content: String, images: [Data] = []) {
        self.role = role
        self.content = content
        self.images = images
    }
}

/// Ошибка, которую бросает `LLMProvider`. Отмена — не ошибка (см. `LLMProvider.streamReply`).
struct LLMError: Error, Hashable, Sendable {
    let kind: ErrorKind
    /// Значение `retry-after` при 429.
    let retryAfter: Duration?

    init(kind: ErrorKind, retryAfter: Duration? = nil) {
        self.kind = kind
        self.retryAfter = retryAfter
    }
}
