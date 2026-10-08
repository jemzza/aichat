import Foundation

/// Сообщения нет — например, чат удалили во время стриминга.
/// `ChatService` глотает эту ошибку при записи ответа.
struct MessageNotFound: Error, Hashable, Sendable {
    let id: UUID
}

struct ChatNotFound: Error, Hashable, Sendable {
    let id: UUID
}

struct FolderNotFound: Error, Hashable, Sendable {
    let id: UUID
}
