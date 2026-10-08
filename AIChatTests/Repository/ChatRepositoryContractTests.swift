import Foundation
import Testing
@testable import AIChat

/// Реализации `ChatRepository`, на которых гоняется один и тот же контракт.
/// GRDB — на отдельной in-memory базе для каждого теста.
enum RepositoryKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case inMemory
    case grdb

    func make() -> any ChatRepository {
        switch self {
        case .inMemory: InMemoryChatRepository()
        case .grdb: GRDBChatRepository(database: try! AppDatabase.inMemory())
        }
    }

    var testDescription: String { rawValue }
}

/// Фиксированное время, чтобы порядок не зависел от часов.
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func makeChat(_ title: String = "Chat", at seconds: TimeInterval = 0) -> Chat {
    Chat(id: UUID(), title: title, createdAt: at(seconds), updatedAt: at(seconds))
}

private func userMessage(_ chat: Chat, _ text: String = "Hi", status: MessageStatus = .sent,
                         at seconds: TimeInterval = 0) -> Message {
    Message(chatId: chat.id, role: .user, text: text, status: status, createdAt: at(seconds))
}

private func reply(_ chat: Chat, _ text: String = "Hello", status: MessageStatus = .done,
                   failure: MessageFailure? = nil, at seconds: TimeInterval = 1) -> Message {
    Message(chatId: chat.id, role: .assistant, text: text, status: status, failure: failure, createdAt: at(seconds))
}

/// Создаёт чат с первым сообщением и возвращает их.
@discardableResult
private func seedChat(_ repository: any ChatRepository, title: String = "Chat",
                      at seconds: TimeInterval = 0) async throws -> (Chat, Message) {
    let chat = makeChat(title, at: seconds)
    let first = userMessage(chat, at: seconds)
    try await repository.insertChat(chat, firstMessage: first)
    return (chat, first)
}

private func messages(_ repository: any ChatRepository, _ chat: Chat,
                      where predicate: @escaping @Sendable ([Message]) -> Bool = { _ in true }) async throws -> [Message] {
    try await firstValue(of: repository.observeMessages(chatId: chat.id), where: predicate)
}

private func message(_ repository: any ChatRepository, _ chat: Chat, id: UUID) async throws -> Message? {
    try await messages(repository, chat).first { $0.id == id }
}

@Suite("ChatRepository contract")
struct ChatRepositoryContractTests {

    // MARK: Чаты

    @Test(arguments: RepositoryKind.allCases)
    func insertChatStoresChatWithFirstMessage(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let chat = makeChat(at: 0)
        let first = userMessage(chat, at: 5)

        try await repository.insertChat(chat, firstMessage: first)

        let chats = try await firstValue(of: repository.observeChats()) { !$0.isEmpty }
        #expect(chats.map(\.id) == [chat.id])
        #expect(chats.first?.updatedAt == at(5))
        #expect(try await messages(repository, chat) == [first])
    }

    @Test(arguments: RepositoryKind.allCases)
    func observeChatsStartsEmptyAndSortsByLastActivity(kind: RepositoryKind) async throws {
        let repository = kind.make()
        #expect(try await firstValue(of: repository.observeChats()).isEmpty)

        let (older, _) = try await seedChat(repository, title: "Older", at: 0)
        let (newer, _) = try await seedChat(repository, title: "Newer", at: 10)
        var chats = try await firstValue(of: repository.observeChats()) { $0.count == 2 }
        #expect(chats.map(\.id) == [newer.id, older.id])

        try await repository.insertMessage(reply(older, at: 20))
        chats = try await firstValue(of: repository.observeChats()) { $0.first?.id == older.id }
        #expect(chats.first?.updatedAt == at(20))
    }

    @Test(arguments: RepositoryKind.allCases)
    func renameChat(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let (chat, _) = try await seedChat(repository)

        try await repository.renameChat(id: chat.id, title: "Renamed")

        let chats = try await firstValue(of: repository.observeChats()) { $0.first?.title == "Renamed" }
        #expect(chats.count == 1)
        await #expect(throws: ChatNotFound(id: chat.id)) {
            try await repository.deleteChat(id: chat.id)
            try await repository.renameChat(id: chat.id, title: "Gone")
        }
    }

    @Test(arguments: RepositoryKind.allCases)
    func deleteChatCascadesAndIsIdempotent(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let (chat, first) = try await seedChat(repository)
        let (other, _) = try await seedChat(repository, title: "Other", at: 1)

        try await repository.deleteChat(id: chat.id)
        try await repository.deleteChat(id: chat.id)

        #expect(try await messages(repository, chat).isEmpty)
        let chats = try await firstValue(of: repository.observeChats()) { $0.count == 1 }
        #expect(chats.map(\.id) == [other.id])
        await #expect(throws: MessageNotFound(id: first.id)) {
            try await repository.updateMessage(id: first.id, text: "x", status: .sent, failure: nil)
        }
    }

    // MARK: Сообщения

    @Test(arguments: RepositoryKind.allCases)
    func messagesAreOrderedByTimeThenInsertion(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let (chat, first) = try await seedChat(repository, at: 0)
        let late = reply(chat, "late", at: 10)
        let sameTimeA = reply(chat, "a", at: 5)
        let sameTimeB = reply(chat, "b", at: 5)

        try await repository.insertMessage(late)
        try await repository.insertMessage(sameTimeA)
        try await repository.insertMessage(sameTimeB)

        let ids = try await messages(repository, chat) { $0.count == 4 }.map(\.id)
        #expect(ids == [first.id, sameTimeA.id, sameTimeB.id, late.id])
    }

    @Test(arguments: RepositoryKind.allCases)
    func insertMessageIntoMissingChatThrows(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let chat = makeChat()
        await #expect(throws: ChatNotFound(id: chat.id)) {
            try await repository.insertMessage(userMessage(chat))
        }
    }

    @Test(arguments: RepositoryKind.allCases)
    func updateMessageChangesTextStatusAndFailure(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let (chat, _) = try await seedChat(repository)
        let answer = reply(chat, "", status: .streaming)
        try await repository.insertMessage(answer)
        let failure = MessageFailure(kind: .rateLimited, retryAt: at(60))

        try await repository.updateMessage(id: answer.id, text: "partial", status: .failed, failure: failure)

        let stored = try await message(repository, chat, id: answer.id)
        #expect(stored?.text == "partial")
        #expect(stored?.status == .failed)
        #expect(stored?.failure == failure)
    }

    /// Чат удалили во время стриминга: запоздавшая запись не падает, а даёт MessageNotFound.
    @Test(arguments: RepositoryKind.allCases)
    func updateMessageAfterChatDeletionThrowsMessageNotFound(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let (chat, _) = try await seedChat(repository)
        let answer = reply(chat, "", status: .streaming)
        try await repository.insertMessage(answer)

        try await repository.deleteChat(id: chat.id)

        await #expect(throws: MessageNotFound(id: answer.id)) {
            try await repository.updateMessage(id: answer.id, text: "late token", status: .done, failure: nil)
        }
        let unknown = UUID()
        await #expect(throws: MessageNotFound(id: unknown)) {
            try await repository.updateMessage(id: unknown, text: "", status: .done, failure: nil)
        }
    }

    // MARK: История для LLM

    @Test(arguments: RepositoryKind.allCases)
    func historyIncludesOnlyContextMessagesBeforeGivenOne(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let (chat, first) = try await seedChat(repository, at: 0)
        let done = reply(chat, "done", status: .done, at: 1)
        let failed = reply(chat, "", status: .failed, failure: MessageFailure(kind: .server), at: 2)
        let interrupted = reply(chat, "half", status: .interrupted, at: 3)
        let cancelled = reply(chat, "partial", status: .cancelled, at: 4)
        let cancelledEmpty = reply(chat, "", status: .cancelled, at: 5)
        let pending = userMessage(chat, "queued", status: .pending, at: 6)
        let question = userMessage(chat, "question", status: .sent, at: 7)
        let current = reply(chat, "", status: .streaming, at: 8)
        let after = userMessage(chat, "after", status: .sent, at: 9)
        for message in [done, failed, interrupted, cancelled, cancelledEmpty, pending, question, current, after] {
            try await repository.insertMessage(message)
        }

        let history = try await repository.history(chatId: chat.id, before: current.id, limit: 100)

        #expect(history.map(\.id) == [first.id, done.id, cancelled.id, question.id])
    }

    @Test(arguments: RepositoryKind.allCases)
    func historyKeepsOnlyLastLimitMessages(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let (chat, _) = try await seedChat(repository, at: 0)
        var inserted: [Message] = []
        for index in 1...6 {
            let message = index.isMultiple(of: 2)
                ? reply(chat, "a\(index)", at: Double(index))
                : userMessage(chat, "q\(index)", at: Double(index))
            try await repository.insertMessage(message)
            inserted.append(message)
        }
        let current = reply(chat, "", status: .streaming, at: 100)
        try await repository.insertMessage(current)

        let history = try await repository.history(chatId: chat.id, before: current.id, limit: 3)
        #expect(history.map(\.id) == inserted.suffix(3).map(\.id))
        #expect(try await repository.history(chatId: chat.id, before: current.id, limit: 0).isEmpty)
    }

    @Test(arguments: RepositoryKind.allCases)
    func historyForUnknownMessageThrows(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let (chat, _) = try await seedChat(repository)
        let unknown = UUID()
        await #expect(throws: MessageNotFound(id: unknown)) {
            try await repository.history(chatId: chat.id, before: unknown, limit: 10)
        }
    }

    // MARK: Outbox

    @Test(arguments: RepositoryKind.allCases)
    func pendingMessagesAreUserPendingOldestFirst(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let (chatA, _) = try await seedChat(repository, at: 0)
        let (chatB, _) = try await seedChat(repository, at: 1)
        let later = userMessage(chatA, "later", status: .pending, at: 20)
        let earlier = userMessage(chatB, "earlier", status: .pending, at: 10)
        try await repository.insertMessage(later)
        try await repository.insertMessage(earlier)
        try await repository.insertMessage(reply(chatA, status: .streaming, at: 30))

        #expect(try await repository.pendingMessages().map(\.id) == [earlier.id, later.id])
    }

    @Test(arguments: RepositoryKind.allCases)
    func claimPendingSucceedsOnlyOnce(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let chat = makeChat()
        let question = userMessage(chat, status: .pending, at: 0)
        try await repository.insertChat(chat, firstMessage: question)
        let answer = reply(chat, "", status: .streaming, at: 1)
        let duplicateAnswer = reply(chat, "", status: .streaming, at: 2)

        #expect(try await repository.claimPending(messageId: question.id, reply: answer))
        #expect(try await repository.claimPending(messageId: question.id, reply: duplicateAnswer) == false)

        let stored = try await messages(repository, chat) { $0.count == 2 }
        #expect(stored.map(\.id) == [question.id, answer.id])
        #expect(stored.first?.status == .sent)
        #expect(try await repository.pendingMessages().isEmpty)
    }

    @Test(arguments: RepositoryKind.allCases)
    func claimPendingRejectsNonPendingAndMissing(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let (chat, sent) = try await seedChat(repository)
        #expect(try await repository.claimPending(messageId: sent.id, reply: reply(chat, status: .streaming)) == false)

        let unknown = UUID()
        await #expect(throws: MessageNotFound(id: unknown)) {
            try await repository.claimPending(messageId: unknown, reply: reply(chat, status: .streaming))
        }
    }

    // MARK: Повтор

    @Test(arguments: RepositoryKind.allCases, [MessageStatus.failed, .interrupted, .cancelled, .done])
    func claimRetryResetsReplyOnlyOnce(kind: RepositoryKind, status: MessageStatus) async throws {
        let repository = kind.make()
        let (chat, _) = try await seedChat(repository)
        let failure = status == .failed ? MessageFailure(kind: .rateLimited, retryAt: at(30)) : nil
        let answer = reply(chat, "partial", status: status, failure: failure)
        try await repository.insertMessage(answer)

        #expect(try await repository.claimRetry(assistantMessageId: answer.id))
        #expect(try await repository.claimRetry(assistantMessageId: answer.id) == false)

        let stored = try await message(repository, chat, id: answer.id)
        #expect(stored?.status == .streaming)
        #expect(stored?.text == "")
        #expect(stored?.failure == nil)
    }

    @Test(arguments: RepositoryKind.allCases, [MessageStatus.streaming])
    func claimRetryRejectsNonRetryableReply(kind: RepositoryKind, status: MessageStatus) async throws {
        let repository = kind.make()
        let (chat, _) = try await seedChat(repository)
        let answer = reply(chat, "text", status: status)
        try await repository.insertMessage(answer)

        #expect(try await repository.claimRetry(assistantMessageId: answer.id) == false)
        #expect(try await message(repository, chat, id: answer.id)?.text == "text")
    }

    @Test(arguments: RepositoryKind.allCases)
    func claimRetryRejectsUserMessageAndThrowsForMissing(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let (_, question) = try await seedChat(repository)
        #expect(try await repository.claimRetry(assistantMessageId: question.id) == false)

        let unknown = UUID()
        await #expect(throws: MessageNotFound(id: unknown)) {
            try await repository.claimRetry(assistantMessageId: unknown)
        }
    }

    // MARK: Старт приложения

    @Test(arguments: RepositoryKind.allCases)
    func markStreamingAsInterruptedChangesOnlyStreaming(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let (chatA, _) = try await seedChat(repository, at: 0)
        let (chatB, _) = try await seedChat(repository, at: 1)
        let streamingA = reply(chatA, "a", status: .streaming, at: 2)
        let streamingB = reply(chatB, "b", status: .streaming, at: 3)
        let alreadyInterrupted = reply(chatA, "c", status: .interrupted, at: 4)
        let done = reply(chatB, "d", status: .done, at: 5)
        for message in [streamingA, streamingB, alreadyInterrupted, done] {
            try await repository.insertMessage(message)
        }

        #expect(try await repository.markStreamingAsInterrupted() == 2)
        #expect(try await repository.markStreamingAsInterrupted() == 0)

        #expect(try await message(repository, chatA, id: streamingA.id)?.status == .interrupted)
        #expect(try await message(repository, chatB, id: streamingB.id)?.status == .interrupted)
        #expect(try await message(repository, chatB, id: done.id)?.status == .done)
    }

    // MARK: Фото

    @Test(arguments: RepositoryKind.allCases)
    func imagesAreStoredWithMessagesInOrder(kind: RepositoryKind) async throws {
        let repository = kind.make()
        let chat = makeChat()
        let photos = [ImageAttachment(jpegData: Data([1, 2])), ImageAttachment(jpegData: Data([3]))]
        let first = Message(chatId: chat.id, role: .user, text: "Look", status: .sent, images: photos, createdAt: at(0))
        try await repository.insertChat(chat, firstMessage: first)
        let answer = reply(chat, at: 1)
        try await repository.insertMessage(answer)
        let pending = Message(chatId: chat.id, role: .user, text: "", status: .pending,
                              images: [ImageAttachment(jpegData: Data([4]))], createdAt: at(2))
        try await repository.insertMessage(pending)

        let stored = try await messages(repository, chat) { $0.count == 3 }
        #expect(stored.map(\.images) == [photos, [], pending.images])
        #expect(try await repository.pendingMessages().map(\.images) == [pending.images])

        // Ответ из outbox: фото вопроса остаются на месте, стрим их не трогает.
        let streaming = reply(chat, "", status: .streaming, at: 3)
        #expect(try await repository.claimPending(messageId: pending.id, reply: streaming))
        try await repository.updateMessage(id: streaming.id, text: "A cat", status: .done, failure: nil)
        let history = try await repository.history(chatId: chat.id, before: streaming.id, limit: 10)
        #expect(history.map(\.images) == [photos, [], pending.images])
        #expect(try await repository.history(chatId: chat.id, before: streaming.id, limit: 1).map(\.images)
                == [pending.images])
    }
}
