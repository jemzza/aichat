import Foundation

/// Единственный источник правды о чатах и сообщениях.
protocol ChatRepository: Sendable {
    // MARK: Наблюдение
    // Первое значение приходит сразу, дальше — при каждом изменении.

    /// Все чаты (в том числе лежащие в папках), новые (по `updatedAt`) сверху.
    func observeChats() -> AsyncStream<[Chat]>
    /// Папки по `position` с их чатами + чаты без папки («Recents»); внутри секций — новые сверху.
    func observeSidebar() -> AsyncStream<SidebarSnapshot>
    /// Сообщения чата по `createdAt`, при равенстве — по порядку вставки.
    func observeMessages(chatId: UUID) -> AsyncStream<[Message]>

    // MARK: Чаты

    /// Создаёт чат вместе с первым сообщением в одной транзакции —
    /// пустых чатов в хранилище не бывает. `updatedAt` чата = `firstMessage.createdAt`.
    /// - Throws: `FolderNotFound`, если `chat.folderId` указывает на несуществующую папку.
    func insertChat(_ chat: Chat, firstMessage: Message) async throws
    /// - Throws: `ChatNotFound`.
    func renameChat(id: UUID, title: String) async throws
    /// Удаляет чат и каскадом его сообщения. Отсутствующий чат — не ошибка.
    func deleteChat(id: UUID) async throws
    /// Переносит чат в папку; `folderId == nil` — в «Recents». `updatedAt` не меняется.
    /// - Throws: `ChatNotFound`, `FolderNotFound` (чат при этом остаётся где был).
    func moveChat(id: UUID, toFolder folderId: UUID?) async throws
    /// Удаляет все чаты, папки, сообщения и вложения одной транзакцией («Delete all chats»).
    func deleteAll() async throws

    // MARK: Папки

    /// Новая папка в конце списка. Имя не проверяется — это забота ViewModel.
    func createFolder(id: UUID, name: String, createdAt: Date) async throws
    /// - Throws: `FolderNotFound`.
    func renameFolder(id: UUID, name: String) async throws
    /// Удаляет папку; её чаты возвращаются в «Recents», позиции остальных папок уплотняются.
    /// Отсутствующая папка — не ошибка.
    func deleteFolder(id: UUID) async throws
    /// Ставит папку на место `index` в итоговом списке (зажимается в `0..<count`),
    /// остальные сдвигаются.
    /// - Throws: `FolderNotFound`.
    func moveFolder(id: UUID, to index: Int) async throws

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
