#if DEBUG
import Foundation
import Synchronization

/// Репозиторий в памяти с тем же контрактом, что и GRDB-реализация
/// (проверяется общими контрактными тестами). Для превью, DEBUG-хука `-mockData` и тестов.
final class InMemoryChatRepository: ChatRepository {
    private struct StoredMessage {
        var message: Message
        /// Порядок вставки — аналог rowid для сортировки при равном `createdAt`.
        let sequence: Int
    }

    private struct MessageObserver {
        let chatId: UUID
        let continuation: AsyncStream<[Message]>.Continuation
    }

    private struct State {
        var chats: [UUID: Chat] = [:]
        var messages: [UUID: StoredMessage] = [:]
        var nextSequence = 0
        var chatObservers: [UUID: AsyncStream<[Chat]>.Continuation] = [:]
        var messageObservers: [UUID: MessageObserver] = [:]

        var sortedChats: [Chat] {
            chats.values.sorted { ($0.updatedAt, $0.createdAt) > ($1.updatedAt, $1.createdAt) }
        }

        func sortedMessages(chatId: UUID) -> [Message] {
            messages.values
                .filter { $0.message.chatId == chatId }
                .sorted { ($0.message.createdAt, $0.sequence) < ($1.message.createdAt, $1.sequence) }
                .map(\.message)
        }

        mutating func append(_ message: Message) {
            messages[message.id] = StoredMessage(message: message, sequence: nextSequence)
            nextSequence += 1
            if var chat = chats[message.chatId] {
                chat.updatedAt = max(chat.updatedAt, message.createdAt)
                chats[message.chatId] = chat
            }
        }

        /// Рассылает свежие снимки. `yield` потокобезопасен и не вызывает код подписчика синхронно,
        /// поэтому его можно звать под замком.
        func notify(chatIds: Set<UUID>, chatsChanged: Bool) {
            if chatsChanged {
                let snapshot = sortedChats
                for continuation in chatObservers.values { continuation.yield(snapshot) }
            }
            for observer in messageObservers.values where chatIds.contains(observer.chatId) {
                observer.continuation.yield(sortedMessages(chatId: observer.chatId))
            }
        }
    }

    private let state = Mutex(State())

    init(chats: [Chat] = [], messages: [Message] = []) {
        state.withLock { state in
            for chat in chats { state.chats[chat.id] = chat }
            for message in messages { state.append(message) }
        }
    }

    // MARK: Наблюдение

    func observeChats() -> AsyncStream<[Chat]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            state.withLock { state in
                state.chatObservers[id] = continuation
                continuation.yield(state.sortedChats)
            }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.chatObservers.removeValue(forKey: id) }
            }
        }
    }

    func observeMessages(chatId: UUID) -> AsyncStream<[Message]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            state.withLock { state in
                state.messageObservers[id] = MessageObserver(chatId: chatId, continuation: continuation)
                continuation.yield(state.sortedMessages(chatId: chatId))
            }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.messageObservers.removeValue(forKey: id) }
            }
        }
    }

    // MARK: Чаты

    func insertChat(_ chat: Chat, firstMessage: Message) throws {
        guard firstMessage.chatId == chat.id else { throw ChatNotFound(id: firstMessage.chatId) }
        state.withLock { state in
            var chat = chat
            chat.updatedAt = firstMessage.createdAt
            state.chats[chat.id] = chat
            state.append(firstMessage)
            state.notify(chatIds: [chat.id], chatsChanged: true)
        }
    }

    func renameChat(id: UUID, title: String) throws {
        try state.withLock { state in
            guard var chat = state.chats[id] else { throw ChatNotFound(id: id) }
            chat.title = title
            state.chats[id] = chat
            state.notify(chatIds: [], chatsChanged: true)
        }
    }

    func deleteChat(id: UUID) {
        state.withLock { state in
            guard state.chats.removeValue(forKey: id) != nil else { return }
            state.messages = state.messages.filter { $0.value.message.chatId != id }
            state.notify(chatIds: [id], chatsChanged: true)
        }
    }

    // MARK: Сообщения

    func insertMessage(_ message: Message) throws {
        try state.withLock { state in
            guard state.chats[message.chatId] != nil else { throw ChatNotFound(id: message.chatId) }
            state.append(message)
            state.notify(chatIds: [message.chatId], chatsChanged: true)
        }
    }

    func updateMessage(id: UUID, text: String, status: MessageStatus, failure: MessageFailure?) throws {
        try state.withLock { state in
            guard var stored = state.messages[id] else { throw MessageNotFound(id: id) }
            stored.message.text = text
            stored.message.status = status
            stored.message.failure = failure
            state.messages[id] = stored
            state.notify(chatIds: [stored.message.chatId], chatsChanged: false)
        }
    }

    func history(chatId: UUID, before messageId: UUID, limit: Int) throws -> [Message] {
        try state.withLock { state in
            let ordered = state.sortedMessages(chatId: chatId)
            guard let index = ordered.firstIndex(where: { $0.id == messageId }) else {
                throw MessageNotFound(id: messageId)
            }
            return Array(ordered[..<index].filter(\.isLLMContext).suffix(max(limit, 0)))
        }
    }

    // MARK: Outbox, повтор, старт

    func pendingMessages() -> [Message] {
        state.withLock { state in
            state.messages.values
                .filter { $0.message.role == .user && $0.message.status == .pending }
                .sorted { ($0.message.createdAt, $0.sequence) < ($1.message.createdAt, $1.sequence) }
                .map(\.message)
        }
    }

    func claimPending(messageId: UUID, reply: Message) throws -> Bool {
        try state.withLock { state in
            guard var stored = state.messages[messageId] else { throw MessageNotFound(id: messageId) }
            guard stored.message.role == .user, stored.message.status == .pending else { return false }
            stored.message.status = .sent
            state.messages[messageId] = stored
            state.append(reply)
            state.notify(chatIds: [stored.message.chatId], chatsChanged: true)
            return true
        }
    }

    func claimRetry(assistantMessageId: UUID) throws -> Bool {
        try state.withLock { state in
            guard var stored = state.messages[assistantMessageId] else {
                throw MessageNotFound(id: assistantMessageId)
            }
            guard stored.message.role == .assistant, stored.message.status.isRetryable else { return false }
            stored.message.status = .streaming
            stored.message.text = ""
            stored.message.failure = nil
            state.messages[assistantMessageId] = stored
            state.notify(chatIds: [stored.message.chatId], chatsChanged: false)
            return true
        }
    }

    @discardableResult
    func markStreamingAsInterrupted() -> Int {
        state.withLock { state in
            var changedChats = Set<UUID>()
            var count = 0
            for (id, var stored) in state.messages where stored.message.status == .streaming {
                stored.message.status = .interrupted
                state.messages[id] = stored
                changedChats.insert(stored.message.chatId)
                count += 1
            }
            state.notify(chatIds: changedChats, chatsChanged: false)
            return count
        }
    }
}
#endif
