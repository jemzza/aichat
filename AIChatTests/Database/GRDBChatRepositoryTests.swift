import Foundation
import GRDB
import Testing
@testable import AIChat

/// То, что контрактные тесты не покрывают: транзакции и поведение поверх настоящей SQLite.
/// Сам контракт `ChatRepository` проверяется общими параметризованными тестами.
@Suite("GRDBChatRepository")
struct GRDBChatRepositoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeChat() -> Chat {
        Chat(id: UUID(), title: "Chat", createdAt: t0, updatedAt: t0)
    }

    /// Двойной «Retry» / одновременный разбор outbox: выигрывает ровно один.
    @Test func concurrentClaimsSucceedExactlyOnce() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBChatRepository(database: database)
        let chat = makeChat()
        let question = Message(chatId: chat.id, role: .user, text: "Hi", status: .pending, createdAt: t0)
        try await repository.insertChat(chat, firstMessage: question)

        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<10 {
                let reply = Message(chatId: chat.id, role: .assistant, text: "", status: .streaming,
                                    createdAt: t0.addingTimeInterval(Double(index + 1)))
                group.addTask { try await repository.claimPending(messageId: question.id, reply: reply) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.filter { $0 }.count == 1)
        let count = try await database.writer.read { try MessageRecord.fetchCount($0) }
        #expect(count == 2)
    }

    /// Чат без первого сообщения не остаётся: ошибка вставки сообщения откатывает и чат.
    @Test func insertChatIsAtomic() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBChatRepository(database: database)
        let existing = makeChat()
        let first = Message(chatId: existing.id, role: .user, text: "Hi", status: .sent, createdAt: t0)
        try await repository.insertChat(existing, firstMessage: first)

        // Тот же id первого сообщения — нарушение первичного ключа на второй вставке.
        let chat = makeChat()
        let duplicate = Message(id: first.id, chatId: chat.id, role: .user, text: "Dup", status: .sent, createdAt: t0)
        await #expect(throws: DatabaseError.self) {
            try await repository.insertChat(chat, firstMessage: duplicate)
        }

        let chatCount = try await database.writer.read { try ChatRecord.fetchCount($0) }
        #expect(chatCount == 1)
    }

    /// Наблюдение видит записи другого экземпляра репозитория на той же базе.
    @Test func observationSeesWritesFromAnotherRepository() async throws {
        let database = try AppDatabase.inMemory()
        let reader = GRDBChatRepository(database: database)
        let writer = GRDBChatRepository(database: database)
        // Поток один на потребителя: отмена firstValue его завершает, поэтому читаем его один раз.
        let chats = reader.observeChats()

        let chat = makeChat()
        try await writer.insertChat(chat, firstMessage: Message(chatId: chat.id, role: .user, text: "Hi",
                                                                status: .sent, createdAt: t0))

        #expect(try await firstValue(of: chats) { !$0.isEmpty }.map(\.id) == [chat.id])
    }

    /// Дробные секунды переживают запись и чтение — сравнение сообщений по `==` надёжно.
    @Test func preservesSubmillisecondDates() async throws {
        let repository = GRDBChatRepository(database: try AppDatabase.inMemory())
        let now = Date()
        let chat = Chat(id: UUID(), title: "Chat", createdAt: now, updatedAt: now)
        let first = Message(chatId: chat.id, role: .user, text: "Hi", status: .sent, createdAt: now)
        try await repository.insertChat(chat, firstMessage: first)

        #expect(try await firstValue(of: repository.observeMessages(chatId: chat.id)) == [first])
        #expect(try await firstValue(of: repository.observeChats()) == [chat])
    }
}
