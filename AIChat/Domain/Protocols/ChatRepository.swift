import Foundation

/// Единственный источник правды о чатах и сообщениях.
protocol ChatRepository: Sendable {
    // MARK: Наблюдение
    // Первое значение приходит сразу, дальше — при каждом изменении.

    /// Чаты, новые (по `updatedAt`) сверху.
    func observeChats() -> AsyncStream<[Chat]>
    /// Сообщения чата по `createdAt`, при равенстве — по порядку вставки.
    func observeMessages(chatId: UUID) -> AsyncStream<[Message]>

    // MARK: Чаты

    /// Создаёт чат вместе с первым сообщением в одной транзакции —
    /// пустых чатов в хранилище не бывает. `updatedAt` чата = `firstMessage.createdAt`.
    func insertChat(_ chat: Chat, firstMessage: Message) async throws
    /// - Throws: `ChatNotFound`.
    func renameChat(id: UUID, title: String) async throws
    /// Удаляет чат и каскадом его сообщения. Отсутствующий чат — не ошибка.
    func deleteChat(id: UUID) async throws

    // MARK: Сообщения

    /// Добавляет сообщение и сдвигает `updatedAt` чата на `message.createdAt`.
    /// - Throws: `ChatNotFound`.
    func insertMessage(_ message: Message) async throws
    /// - Throws: `MessageNotFound`, если сообщения уже нет (чат удалён во время стрима).
    func updateMessage(id: UUID, text: String, status: MessageStatus, failure: MessageFailure?) async throws
    /// Контекст для LLM: сообщения чата, стоящие перед `messageId`, — user со статусом `sent`,
    /// assistant со статусом `done`/`cancelled` и непустым текстом; не больше `limit` последних.
    /// - Throws: `MessageNotFound`.
    func history(chatId: UUID, before messageId: UUID, limit: Int) async throws -> [Message]

    // MARK: Outbox, повтор, старт

    /// Сообщения пользователя в статусе `pending`, старые первыми.
    func pendingMessages() async throws -> [Message]
    /// Атомарно: user `pending` → `sent` и вставка `reply` (assistant, `streaming`).
    /// - Returns: `false`, если сообщение уже не `pending` (забрали раньше).
    /// - Throws: `MessageNotFound`.
    func claimPending(messageId: UUID, reply: Message) async throws -> Bool
    /// Атомарно: ответ `failed`/`interrupted`/`cancelled` → `streaming`, очищает `text` и `failure`.
    /// - Returns: `false`, если ответ уже `streaming`/`done` или это не ответ ассистента.
    /// - Throws: `MessageNotFound`.
    func claimRetry(assistantMessageId: UUID) async throws -> Bool
    /// При запуске: все `streaming` → `interrupted`.
    /// - Returns: сколько сообщений изменено.
    @discardableResult
    func markStreamingAsInterrupted() async throws -> Int
}
