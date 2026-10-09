import Foundation
import GRDB

/// `ChatRepository` поверх GRDB. Каждый метод записи — одна транзакция (`writer.write`),
/// поэтому проверки «claim»-методов и сами изменения атомарны.
final class GRDBChatRepository: ChatRepository {
    private let writer: any DatabaseWriter
    /// Очередь, на которой GRDB доставляет значения наблюдения в `AsyncStream`.
    private let observationQueue = DispatchQueue(label: "GRDBChatRepository.observation")

    init(database: AppDatabase) {
        writer = database.writer
    }

    /// Репозиторий для запуска приложения: ответы, которые стримились, когда процесс
    /// умер, переводятся в `interrupted` раньше, чем кто-то подпишется на базу.
    static func launch(database: AppDatabase) async throws -> GRDBChatRepository {
        let repository = GRDBChatRepository(database: database)
        try await repository.markStreamingAsInterrupted()
        return repository
    }

    // MARK: Наблюдение

    func observeChats() -> AsyncStream<[Chat]> {
        observe { db in
            try ChatRecord.byLastActivity().fetchAll(db).map(\.chat)
        }
    }

    func observeSidebar() -> AsyncStream<SidebarSnapshot> {
        observe { db in
            // Одно чтение — согласованный снимок папок и чатов.
            SidebarSnapshot(
                folders: try FolderRecord.ordered().fetchAll(db).map(\.folder),
                chats: try ChatRecord.byLastActivity().fetchAll(db).map(\.chat)
            )
        }
    }

    func observeMessages(chatId: UUID) -> AsyncStream<[Message]> {
        observe { db in
            let records = try MessageRecord.chronological()
                .filter(MessageRecord.Columns.chatId == chatId)
                .fetchAll(db)
            return try MessageRecord.messages(records, db)
        }
    }

    /// Первое значение — сразу после подписки, дальше — после каждой транзакции,
    /// затронувшей прочитанные таблицы (одинаковые снимки подряд отбрасываются).
    /// Ошибка чтения завершает поток. Отмена потребителя останавливает наблюдение.
    private func observe<Value: Equatable & Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncStream<Value> {
        let observation = ValueObservation.trackingConstantRegion(fetch).removeDuplicates()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let cancellable = observation.start(
                in: writer,
                scheduling: .async(onQueue: observationQueue),
                onError: { _ in continuation.finish() },
                onChange: { continuation.yield($0) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    // MARK: Чаты

    func insertChat(_ chat: Chat, firstMessage: Message) async throws {
        guard firstMessage.chatId == chat.id else { throw ChatNotFound(id: firstMessage.chatId) }
        var record = ChatRecord(chat)
        record.updatedAt = firstMessage.createdAt
        try await writer.write { [record] db in
            try Self.requireFolder(record.folderId, db)
            try record.insert(db)
            try Self.insert(firstMessage, db)
        }
    }

    func renameChat(id: UUID, title: String) async throws {
        let changed = try await writer.write { db in
            try ChatRecord.filter(key: id).updateAll(db, ChatRecord.Columns.title.set(to: title))
        }
        guard changed > 0 else { throw ChatNotFound(id: id) }
    }

    func deleteChat(id: UUID) async throws {
        // Сообщения удаляет `ON DELETE CASCADE`.
        _ = try await writer.write { db in
            try ChatRecord.deleteOne(db, key: id)
        }
    }

    func moveChat(id: UUID, toFolder folderId: UUID?) async throws {
        try await writer.write { db in
            guard try ChatRecord.exists(db, key: id) else { throw ChatNotFound(id: id) }
            // Проверяем сами, а не ждём ошибку FK, — наружу уходит доменная ошибка.
            try Self.requireFolder(folderId, db)
            try ChatRecord.filter(key: id).updateAll(db, ChatRecord.Columns.folderId.set(to: folderId))
        }
    }

    // MARK: Папки

    func createFolder(id: UUID, name: String, createdAt: Date) async throws {
        try await writer.write { db in
            let count = try FolderRecord.fetchCount(db)
            try FolderRecord(id: id, name: name, position: count, createdAt: createdAt).insert(db)
        }
    }

    func renameFolder(id: UUID, name: String) async throws {
        let changed = try await writer.write { db in
            try FolderRecord.filter(key: id).updateAll(db, FolderRecord.Columns.name.set(to: name))
        }
        guard changed > 0 else { throw FolderNotFound(id: id) }
    }

    func deleteFolder(id: UUID) async throws {
        try await writer.write { db in
            // Чаты возвращает в «Recents» `ON DELETE SET NULL`.
            guard try FolderRecord.deleteOne(db, key: id) else { return }
            try Self.renumberFolders(try FolderRecord.ordered().fetchAll(db).map(\.id), db)
        }
    }

    func moveFolder(id: UUID, to index: Int) async throws {
        try await writer.write { db in
            var ids = try FolderRecord.ordered().fetchAll(db).map(\.id)
            guard let current = ids.firstIndex(of: id) else { throw FolderNotFound(id: id) }
            ids.remove(at: current)
            ids.insert(id, at: min(max(index, 0), ids.count))
            try Self.renumberFolders(ids, db)
        }
    }

    // MARK: Сообщения

    func insertMessage(_ message: Message) async throws {
        try await writer.write { db in
            guard try ChatRecord.exists(db, key: message.chatId) else {
                throw ChatNotFound(id: message.chatId)
            }
            try Self.append(message, db)
        }
    }

    func updateMessage(id: UUID, text: String, status: MessageStatus, failure: MessageFailure?) async throws {
        let changed = try await writer.write { db in
            try MessageRecord.filter(key: id).updateAll(db, [
                MessageRecord.Columns.text.set(to: text),
                MessageRecord.Columns.status.set(to: status.rawValue),
                MessageRecord.Columns.failureKind.set(to: failure?.kind.rawValue),
                MessageRecord.Columns.failureRetryAt.set(to: failure?.retryAt?.databaseTimestamp),
            ])
        }
        guard changed > 0 else { throw MessageNotFound(id: id) }
    }

    func history(chatId: UUID, before messageId: UUID, limit: Int) async throws -> [Message] {
        try await writer.read { db in
            let ordered = try MessageRecord.chronological()
                .filter(MessageRecord.Columns.chatId == chatId)
                .fetchAll(db)
            guard let index = ordered.firstIndex(where: { $0.id == messageId }) else {
                throw MessageNotFound(id: messageId)
            }
            // Фильтр — в Swift, чтобы правило контекста жило в одном месте (`Message.isLLMContext`).
            let context = try ordered[..<index].map { try $0.message() }.filter(\.isLLMContext)
            let kept = Set(context.suffix(max(limit, 0)).map(\.id))
            // Фото читаем только для сообщений, которые попадут в запрос.
            return try MessageRecord.messages(ordered[..<index].filter { kept.contains($0.id) }, db)
        }
    }

    // MARK: Outbox, повтор, старт

    func pendingMessages() async throws -> [Message] {
        try await writer.read { db in
            let records = try MessageRecord.chronological()
                .filter(MessageRecord.Columns.role == MessageRole.user.rawValue)
                .filter(MessageRecord.Columns.status == MessageStatus.pending.rawValue)
                .fetchAll(db)
            return try MessageRecord.messages(records, db)
        }
    }

    func claimPending(messageId: UUID, reply: Message) async throws -> Bool {
        try await writer.write { db in
            guard let stored = try MessageRecord.fetchOne(db, key: messageId) else {
                throw MessageNotFound(id: messageId)
            }
            guard stored.role == MessageRole.user.rawValue,
                  stored.status == MessageStatus.pending.rawValue else { return false }
            try MessageRecord.filter(key: messageId)
                .updateAll(db, MessageRecord.Columns.status.set(to: MessageStatus.sent.rawValue))
            try Self.append(reply, db)
            return true
        }
    }

    func claimRetry(assistantMessageId: UUID) async throws -> Bool {
        try await writer.write { db in
            guard let stored = try MessageRecord.fetchOne(db, key: assistantMessageId) else {
                throw MessageNotFound(id: assistantMessageId)
            }
            guard stored.role == MessageRole.assistant.rawValue,
                  MessageStatus(rawValue: stored.status)?.isRetryable == true else { return false }
            try MessageRecord.filter(key: assistantMessageId).updateAll(db, [
                MessageRecord.Columns.status.set(to: MessageStatus.streaming.rawValue),
                MessageRecord.Columns.text.set(to: ""),
                MessageRecord.Columns.failureKind.set(to: nil),
                MessageRecord.Columns.failureRetryAt.set(to: nil),
            ])
            return true
        }
    }

    @discardableResult
    func markStreamingAsInterrupted() async throws -> Int {
        try await writer.write { db in
            try MessageRecord
                .filter(MessageRecord.Columns.status == MessageStatus.streaming.rawValue)
                .updateAll(db, MessageRecord.Columns.status.set(to: MessageStatus.interrupted.rawValue))
        }
    }

    // MARK: Внутреннее

    /// `nil` — «Recents», проверять нечего.
    private static func requireFolder(_ folderId: UUID?, _ db: Database) throws {
        guard let folderId else { return }
        guard try FolderRecord.exists(db, key: folderId) else { throw FolderNotFound(id: folderId) }
    }

    /// Позиции 0..n-1 в порядке `ids`; пишем только изменившиеся.
    private static func renumberFolders(_ ids: [UUID], _ db: Database) throws {
        let current = Dictionary(uniqueKeysWithValues: try FolderRecord.fetchAll(db).map { ($0.id, $0.position) })
        for (position, id) in ids.enumerated() where current[id] != position {
            try FolderRecord.filter(key: id).updateAll(db, FolderRecord.Columns.position.set(to: position))
        }
    }

    /// Вставляет сообщение и сдвигает `updatedAt` чата вперёд (назад — никогда).
    private static func append(_ message: Message, _ db: Database) throws {
        try insert(message, db)
        try db.execute(
            sql: "UPDATE chat SET updatedAt = MAX(updatedAt, ?) WHERE id = ?",
            arguments: [message.createdAt.databaseTimestamp, message.chatId]
        )
    }

    /// Сообщение и его фото.
    private static func insert(_ message: Message, _ db: Database) throws {
        try MessageRecord(message).insert(db)
        for attachment in AttachmentRecord.records(for: message) {
            try attachment.insert(db)
        }
    }
}
