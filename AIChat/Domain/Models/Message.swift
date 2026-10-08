import Foundation

enum MessageRole: String, Hashable, Sendable {
    case user
    case assistant
}

/// Два автомата состояний в одном перечислении (одна колонка в БД):
/// - user: `pending` → `sent`;
/// - assistant: `streaming` → `done` | `cancelled` | `failed` | `interrupted`,
///   повтор возвращает ответ в `streaming`.
enum MessageStatus: String, Hashable, Sendable {
    case pending
    case sent
    case streaming
    case done
    case cancelled
    case failed
    case interrupted

    /// Ответ ассистента в этом статусе можно перезапросить.
    var isRetryable: Bool {
        switch self {
        case .failed, .interrupted, .cancelled: true
        case .pending, .sent, .streaming, .done: false
        }
    }
}

struct Message: Identifiable, Hashable, Sendable {
    let id: UUID
    let chatId: UUID
    let role: MessageRole
    var text: String
    var status: MessageStatus
    /// Только у ответа ассистента со статусом `failed`.
    var failure: MessageFailure?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        chatId: UUID,
        role: MessageRole,
        text: String,
        status: MessageStatus,
        failure: MessageFailure? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.chatId = chatId
        self.role = role
        self.text = text
        self.status = status
        self.failure = failure
        self.createdAt = createdAt
    }
}

extension Message {
    /// Попадает ли сообщение в контекст запроса к LLM (см. `ChatRepository.history`).
    var isLLMContext: Bool {
        switch role {
        case .user: status == .sent
        case .assistant: (status == .done || status == .cancelled) && !text.isEmpty
        }
    }
}
