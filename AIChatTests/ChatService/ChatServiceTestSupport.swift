import Foundation
import Synchronization
@testable import AIChat

/// Часы, которые двигает тест. Спать не умеют — `ChatService` их только читает.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let current = Mutex(Instant(offset: .zero))

    var now: Instant { current.withLock { $0 } }
    var minimumResolution: Duration { .zero }

    func advance(by duration: Duration) {
        current.withLock { $0 = $0.advanced(by: duration) }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {}
}

/// Провайдер, который перед каждым токеном двигает часы — для проверки троттлинга.
struct ClockAdvancingProvider: LLMProvider {
    let tokens: [String]
    let step: Duration
    let clock: ManualClock

    var displayName: LocalizedStringResource { "Test" }

    /// Токен — только когда потребитель его попросил: часы двигаются в такт чтению.
    func streamReply(to messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        let remaining = Mutex(tokens[...])
        let clock = clock
        let step = step
        return AsyncThrowingStream {
            guard let token = remaining.withLock({ $0.popFirst() }) else { return nil }
            clock.advance(by: step)
            return token
        }
    }
}

/// Репозиторий-обёртка: всё передаёт дальше и запоминает вызовы `updateMessage`.
final class RecordingRepository: ChatRepository {
    let base: any ChatRepository
    private let updates = Mutex<[MessageStatus]>([])

    init(base: any ChatRepository) {
        self.base = base
    }

    var updateStatuses: [MessageStatus] { updates.withLock { $0 } }

    func observeChats() -> AsyncStream<[Chat]> { base.observeChats() }
    func observeMessages(chatId: UUID) -> AsyncStream<[Message]> { base.observeMessages(chatId: chatId) }
    func insertChat(_ chat: Chat, firstMessage: Message) async throws {
        try await base.insertChat(chat, firstMessage: firstMessage)
    }
    func renameChat(id: UUID, title: String) async throws { try await base.renameChat(id: id, title: title) }
    func deleteChat(id: UUID) async throws { try await base.deleteChat(id: id) }
    func insertMessage(_ message: Message) async throws { try await base.insertMessage(message) }
    func updateMessage(id: UUID, text: String, status: MessageStatus, failure: MessageFailure?) async throws {
        updates.withLock { $0.append(status) }
        try await base.updateMessage(id: id, text: text, status: status, failure: failure)
    }
    func history(chatId: UUID, before messageId: UUID, limit: Int) async throws -> [Message] {
        try await base.history(chatId: chatId, before: messageId, limit: limit)
    }
    func pendingMessages() async throws -> [Message] { try await base.pendingMessages() }
    func claimPending(messageId: UUID, reply: Message) async throws -> Bool {
        try await base.claimPending(messageId: messageId, reply: reply)
    }
    func claimRetry(assistantMessageId: UUID) async throws -> Bool {
        try await base.claimRetry(assistantMessageId: assistantMessageId)
    }
    func markStreamingAsInterrupted() async throws -> Int { try await base.markStreamingAsInterrupted() }
}

/// Фоновые задачи под контролем теста: можно «забрать время» у генерации.
@MainActor
final class ManualBackgroundTasks: BackgroundTaskScheduling {
    private var expirations: [Int: @MainActor () -> Void] = [:]
    private var nextToken = 1
    private(set) var endedTokens: [Int] = []

    var activeCount: Int { expirations.count }

    func beginTask(expiration: @escaping @MainActor () -> Void) -> Int {
        defer { nextToken += 1 }
        expirations[nextToken] = expiration
        return nextToken
    }

    func endTask(_ token: Int) {
        expirations[token] = nil
        endedTokens.append(token)
    }

    func expireAll() {
        for expiration in expirations.values { expiration() }
    }
}

/// Время, которое идёт вперёд на секунду при каждом вызове: у сообщений разные `createdAt`.
@MainActor
final class SteppingDates {
    private var current: Date

    init(start: Date) {
        current = start
    }

    func next() -> Date {
        current = current.addingTimeInterval(1)
        return current
    }
}
