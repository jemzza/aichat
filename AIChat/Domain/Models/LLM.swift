import Foundation

enum LLMRole: String, Hashable, Sendable {
    case system
    case user
    case assistant
}

struct LLMMessage: Hashable, Sendable {
    let role: LLMRole
    let content: String
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
