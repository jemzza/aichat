import Foundation
import Testing
@testable import AIChat

@MainActor
struct ChatServiceTests {
    private struct Harness {
        let repository: RecordingRepository
        let provider: FakeLLMProvider
        let connectivity: FakeConnectivityMonitor
        let backgroundTasks: ManualBackgroundTasks
        let service: ChatService<ManualClock>
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_000_000)

    private func makeHarness(
        script: FakeLLMProvider.Script = .reply("Hello world", tokenDelay: .zero),
        isOnline: Bool = true,
        provider customProvider: (any LLMProvider)? = nil,
        clock: ManualClock = ManualClock()
    ) throws -> Harness {
        let repository = RecordingRepository(base: GRDBChatRepository(database: try AppDatabase.inMemory()))
        let provider = FakeLLMProvider(script: script)
        let connectivity = FakeConnectivityMonitor(isOnline: isOnline)
        let backgroundTasks = ManualBackgroundTasks()
        let dates = SteppingDates(start: Self.fixedNow)
        let service = ChatService(
            repository: repository,
            provider: customProvider ?? provider,
            connectivity: connectivity,
            backgroundTasks: backgroundTasks,
            clock: clock,
            now: { dates.next() }
        )
        return Harness(repository: repository, provider: provider, connectivity: connectivity,
                       backgroundTasks: backgroundTasks, service: service)
    }

    private func messages(
        _ harness: Harness,
        chatId: UUID,
        where predicate: @escaping @Sendable ([Message]) -> Bool
    ) async throws -> [Message] {
        try await firstValue(of: harness.repository.observeMessages(chatId: chatId), where: predicate)
    }

    // MARK: Отправка

    @Test func onlineSendCreatesChatAndStreamsReplyToDone() async throws {
        let harness = try makeHarness()

        let chatId = try await harness.service.send("Hi there", inChat: nil)

        let messages = try await messages(harness, chatId: chatId) { $0.last?.status == .done }
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages.map(\.status) == [.sent, .done])
        #expect(messages.last?.text == "Hello world")
        let chats = try await firstValue(of: harness.repository.observeChats())
        #expect(chats.map(\.title) == ["Hi there"])
        #expect(harness.provider.requests == [[LLMMessage(role: .user, content: "Hi there")]])
        try await waitUntil { !harness.service.isGenerating(chatId: chatId) }
        #expect(harness.backgroundTasks.activeCount == 0)
    }

    @Test func offlineSendStaysPendingWithoutRequest() async throws {
        let harness = try makeHarness(isOnline: false)

        let chatId = try await harness.service.send("Hi", inChat: nil)

        let messages = try await messages(harness, chatId: chatId) { !$0.isEmpty }
        #expect(messages.map(\.status) == [.pending])
        #expect(harness.provider.requests.isEmpty)
    }

    @Test func draftGrowsByTokensAndClearsAtTheEnd() async throws {
        let harness = try makeHarness(script: .reply("one two three", tokenDelay: .milliseconds(20)))
        let chatId = UUID()
        var drafts = harness.service.draftUpdates(chatId: chatId).makeAsyncIterator()
        #expect(await drafts.next() == .some(nil))

        _ = try await harness.service.send("Count", inChat: chatId)

        var texts: [String] = []
        while let draft = await drafts.next() {
            guard let draft else { break }
            texts.append(draft.text)
        }
        #expect(texts.last == "one two three")
        #expect(texts.contains("one "))
    }

    // MARK: Троттлинг

    /// Часы стоят: в базу — только первый токен и финальная запись.
    @Test func streamingWritesAreThrottled() async throws {
        let harness = try makeHarness(script: .reply("a b c d e f g h", tokenDelay: .zero))

        let chatId = try await harness.service.send("Go", inChat: nil)
        _ = try await messages(harness, chatId: chatId) { $0.last?.status == .done }

        #expect(harness.repository.updateStatuses == [.streaming, .done])
    }

    /// Токен каждые 300 мс при интервале 500 мс: пишем на 1-м, 3-м и 5-м токене + финал.
    @Test func streamingWritesFollowClock() async throws {
        let clock = ManualClock()
        let provider = ClockAdvancingProvider(tokens: ["1 ", "2 ", "3 ", "4 ", "5"], step: .milliseconds(300),
                                              clock: clock)
        let harness = try makeHarness(provider: provider, clock: clock)

        let chatId = try await harness.service.send("Go", inChat: nil)
        let messages = try await messages(harness, chatId: chatId) { $0.last?.status == .done }

        #expect(harness.repository.updateStatuses == [.streaming, .streaming, .streaming, .done])
        #expect(messages.last?.text == "1 2 3 4 5")
    }

    // MARK: Stop, ошибки, Retry

    @Test func stopKeepsPartialTextAsCancelled() async throws {
        let full = "one two three four five six seven eight"
        let harness = try makeHarness(script: .reply(full, tokenDelay: .milliseconds(30)))
        let chatId = try await harness.service.send("Count", inChat: nil)

        var drafts = harness.service.draftUpdates(chatId: chatId).makeAsyncIterator()
        while let draft = await drafts.next() {
            if let draft, draft.text.hasPrefix("one two") { break }
        }
        harness.service.stopGenerating(chatId: chatId)

        let messages = try await messages(harness, chatId: chatId) { $0.last?.status == .cancelled }
        let text = try #require(messages.last?.text)
        #expect(text.hasPrefix("one two"))
        #expect(text != full)
        #expect(messages.last?.failure == nil)
    }

    @Test func providerErrorMarksFailedWithRetryDate() async throws {
        let error = LLMError(kind: .rateLimited, retryAfter: .seconds(30))
        let harness = try makeHarness(script: .fail(error, partialText: "Half ", tokenDelay: .zero))

        let chatId = try await harness.service.send("Go", inChat: nil)

        let messages = try await messages(harness, chatId: chatId) { $0.last?.status == .failed }
        #expect(messages.last?.text == "Half ")
        let failure = try #require(messages.last?.failure)
        #expect(failure.kind == .rateLimited)
        // Время в тесте идёт по секунде за вызов: `retry-after` отсчитан от момента ошибки.
        let retryAt = try #require(failure.retryAt)
        let sent = try #require(messages.first?.createdAt)
        #expect(retryAt.timeIntervalSince(sent) > 30)
        #expect(retryAt.timeIntervalSince(sent) < 40)
    }

    @Test func doubleRetryStartsOneGeneration() async throws {
        let harness = try makeHarness(script: .fail(LLMError(kind: .server), tokenDelay: .zero))
        let chatId = try await harness.service.send("Go", inChat: nil)
        let failed = try await messages(harness, chatId: chatId) { $0.last?.status == .failed }
        let replyId = try #require(failed.last?.id)
        try await waitUntil { !harness.service.isGenerating(chatId: chatId) }
        harness.provider.setScript(.reply("Recovered", tokenDelay: .milliseconds(20)))

        async let first: Void = harness.service.retry(assistantMessageId: replyId, inChat: chatId)
        async let second: Void = harness.service.retry(assistantMessageId: replyId, inChat: chatId)
        _ = try await (first, second)

        let messages = try await messages(harness, chatId: chatId) { $0.last?.status == .done }
        #expect(messages.count == 2)
        #expect(messages.last?.id == replyId)
        #expect(messages.last?.text == "Recovered")
        #expect(harness.provider.requests.count == 2)
    }

    /// Перегенерация: тот же ответ получает новый текст, старый текст в контекст не идёт.
    @Test func regenerateReplacesDoneReplyInPlace() async throws {
        let harness = try makeHarness(script: .reply("First answer", tokenDelay: .zero))
        let chatId = try await harness.service.send("Question", inChat: nil)
        let done = try await messages(harness, chatId: chatId) { $0.last?.status == .done }
        let replyId = try #require(done.last?.id)
        try await waitUntil { !harness.service.isGenerating(chatId: chatId) }
        harness.provider.setScript(.reply("Second answer", tokenDelay: .zero))

        try await harness.service.retry(assistantMessageId: replyId, inChat: chatId)

        let messages = try await messages(harness, chatId: chatId) {
            $0.last?.status == .done && $0.last?.text == "Second answer"
        }
        #expect(messages.count == 2)
        #expect(messages.last?.id == replyId)
        #expect(harness.provider.requests.last == [LLMMessage(role: .user, content: "Question")])
    }

    // MARK: Outbox

    @Test func outboxSendsPendingOnceInOrderWhenOnline() async throws {
        let harness = try makeHarness(script: .reply("Ok", tokenDelay: .zero), isOnline: false)
        let chatId = try await harness.service.send("First", inChat: nil)
        _ = try await harness.service.send("Second", inChat: chatId)
        let run = Task { await harness.service.run() }
        defer { run.cancel() }

        harness.connectivity.setOnline(true)
        // Повторные поводы (foreground, ещё раз сеть) не должны дать второй отправки.
        harness.service.appDidBecomeActive()
        await harness.service.processOutbox()
        harness.connectivity.setOnline(false)
        harness.connectivity.setOnline(true)

        let messages = try await messages(harness, chatId: chatId) {
            $0.count == 4 && $0.allSatisfy { $0.status == .sent || $0.status == .done }
        }
        #expect(messages.map(\.text) == ["First", "Ok", "Second", "Ok"])
        try await waitUntil { !harness.service.isGenerating(chatId: chatId) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.provider.requests.count == 2)
        // Второй запрос видит первый вопрос и ответ на него.
        #expect(harness.provider.requests.last?.map(\.content) == ["First", "Ok", "Second"])
    }

    // MARK: Ответ на устройстве

    private func makeOnDeviceHarness(
        isOnline: Bool = false,
        isAvailable: Bool = true
    ) throws -> (harness: Harness, onDevice: FakeOnDeviceLLMProvider, service: ChatService<ManualClock>) {
        let base = try makeHarness(isOnline: isOnline)
        let onDevice = FakeOnDeviceLLMProvider(script: .reply("Local answer", tokenDelay: .zero),
                                               isAvailable: isAvailable)
        let dates = SteppingDates(start: Self.fixedNow)
        let service = ChatService(repository: base.repository, provider: base.provider,
                                  onDeviceProvider: onDevice, connectivity: base.connectivity,
                                  clock: ManualClock(), now: { dates.next() })
        return (base, onDevice, service)
    }

    @Test func answerOfflineUsesOnDeviceModelForPendingMessage() async throws {
        let (harness, onDevice, service) = try makeOnDeviceHarness()
        let chatId = try await service.send("Question", inChat: nil)
        #expect(service.canAnswerOffline)
        let pending = try await messages(harness, chatId: chatId) { !$0.isEmpty }

        try await service.answerOffline(messageId: try #require(pending.first).id, inChat: chatId)

        let messages = try await messages(harness, chatId: chatId) { $0.last?.status == .done }
        #expect(messages.map(\.status) == [.sent, .done])
        #expect(messages.last?.text == "Local answer")
        #expect(onDevice.requests == [[LLMMessage(role: .user, content: "Question")]])
        #expect(harness.provider.requests.isEmpty)
        // Вопрос уже `sent` — появление сети не отправит его второй раз.
        try await waitUntil { !service.isGenerating(chatId: chatId) }
        harness.connectivity.setOnline(true)
        await service.processOutbox()
        #expect(harness.provider.requests.isEmpty)
    }

    @Test func answerOfflineIsUnavailableOnlineOrWithoutModel() async throws {
        let online = try makeOnDeviceHarness(isOnline: true)
        #expect(!online.service.canAnswerOffline)

        let (harness, onDevice, service) = try makeOnDeviceHarness(isAvailable: false)
        #expect(!service.canAnswerOffline)
        let chatId = try await service.send("Question", inChat: nil)
        let pending = try await messages(harness, chatId: chatId) { !$0.isEmpty }

        try await service.answerOffline(messageId: try #require(pending.first).id, inChat: chatId)

        #expect(try await messages(harness, chatId: chatId) { !$0.isEmpty }.map(\.status) == [.pending])
        #expect(onDevice.requests.isEmpty)
        onDevice.setAvailable(true)
        #expect(service.canAnswerOffline)
    }

    /// Двойное нажатие: второй вызов видит, что сообщение уже не `pending`.
    @Test func doubleAnswerOfflineStartsOneGeneration() async throws {
        let (harness, onDevice, service) = try makeOnDeviceHarness()
        let chatId = try await service.send("Question", inChat: nil)
        let messageId = try #require(try await messages(harness, chatId: chatId) { !$0.isEmpty }.first).id

        async let first: Void = service.answerOffline(messageId: messageId, inChat: chatId)
        async let second: Void = service.answerOffline(messageId: messageId, inChat: chatId)
        _ = try await (first, second)

        let messages = try await messages(harness, chatId: chatId) { $0.last?.status == .done }
        #expect(messages.count == 2)
        #expect(onDevice.requests.count == 1)
    }

    // MARK: Фото

    @Test func photosGoToProviderWithTheQuestion() async throws {
        let harness = try makeHarness()
        let photo = ImageAttachment(jpegData: Data([9]))

        let chatId = try await harness.service.send("What is it?", images: [photo], inChat: nil)

        let messages = try await messages(harness, chatId: chatId) { $0.last?.status == .done }
        #expect(messages.first?.images == [photo])
        #expect(harness.provider.requests == [[LLMMessage(role: .user, content: "What is it?", images: [Data([9])])]])
    }

    @Test func onlyNewestPhotosStayInContext() {
        let old = LLMMessage(role: .user, content: "a", images: [Data([1]), Data([2])])
        let answer = LLMMessage(role: .assistant, content: "b")
        let new = LLMMessage(role: .user, content: "c", images: [Data([3]), Data([4])])

        let kept = ChatService<ManualClock>.keepingNewestImages([old, answer, new], limit: 3)

        #expect(kept.map(\.images) == [[Data([2])], [], [Data([3]), Data([4])]])
        #expect(kept.map(\.content) == ["a", "b", "c"])
    }

    @Test func photoMessageIsNotAnsweredOffline() async throws {
        let (harness, onDevice, service) = try makeOnDeviceHarness()
        let chatId = try await service.send("", images: [ImageAttachment(jpegData: Data([1]))], inChat: nil)
        let pending = try await messages(harness, chatId: chatId) { !$0.isEmpty }

        try await service.answerOffline(messageId: try #require(pending.first).id, inChat: chatId)

        #expect(try await messages(harness, chatId: chatId) { !$0.isEmpty }.map(\.status) == [.pending])
        #expect(onDevice.requests.isEmpty)
    }

    // MARK: Удаление и прерывание

    @Test func deletingChatCancelsGeneration() async throws {
        let harness = try makeHarness(script: .hang)
        let chatId = try await harness.service.send("Go", inChat: nil)
        #expect(harness.service.isGenerating(chatId: chatId))

        try await harness.service.deleteChat(id: chatId)

        try await waitUntil { !harness.service.isGenerating(chatId: chatId) }
        let chats = try await firstValue(of: harness.repository.observeChats())
        #expect(chats.isEmpty)
    }

    /// Чат удалили в обход сервиса — запоздавшая запись получает `MessageNotFound` и глотается.
    @Test func lateWriteToDeletedChatIsSwallowed() async throws {
        let harness = try makeHarness(script: .hang)
        let chatId = try await harness.service.send("Go", inChat: nil)
        try await waitUntil { harness.provider.requests.count == 1 }

        try await harness.repository.deleteChat(id: chatId)
        harness.service.stopGenerating(chatId: chatId)

        try await waitUntil { !harness.service.isGenerating(chatId: chatId) }
        #expect(harness.repository.updateStatuses == [.cancelled])
        #expect(harness.backgroundTasks.activeCount == 0)
    }

    @Test func backgroundExpirationMarksInterrupted() async throws {
        let harness = try makeHarness(script: .hang)
        let chatId = try await harness.service.send("Go", inChat: nil)
        try await waitUntil { harness.provider.requests.count == 1 }
        #expect(harness.backgroundTasks.activeCount == 1)

        harness.backgroundTasks.expireAll()

        let messages = try await messages(harness, chatId: chatId) { $0.last?.status == .interrupted }
        #expect(messages.last?.failure == nil)
        try await waitUntil { harness.backgroundTasks.activeCount == 0 }
    }

    // MARK: Контекст

    @Test func contextSkipsFailedRepliesAndKeepsCancelledText() async throws {
        let harness = try makeHarness(script: .fail(LLMError(kind: .server), tokenDelay: .zero))
        let chatId = try await harness.service.send("One", inChat: nil)
        _ = try await messages(harness, chatId: chatId) { $0.last?.status == .failed }
        try await waitUntil { !harness.service.isGenerating(chatId: chatId) }

        harness.provider.setScript(.reply("Answer", tokenDelay: .zero))
        _ = try await harness.service.send("Two", inChat: chatId)
        _ = try await messages(harness, chatId: chatId) { $0.last?.status == .done }

        #expect(harness.provider.requests.last == [
            LLMMessage(role: .user, content: "One"),
            LLMMessage(role: .user, content: "Two"),
        ])
    }

    @Test func contextIsTrimmedFromTheOldestEnd() {
        let messages = ["aaaa", "bbbb", "cccc"].map { LLMMessage(role: .user, content: $0) }
        let trimmed = ChatService<ManualClock>.trimmed(messages, characterLimit: 9)
        #expect(trimmed.map(\.content) == ["bbbb", "cccc"])
    }

    @Test func lastMessageIsKeptEvenIfLongerThanLimit() {
        let messages = [LLMMessage(role: .user, content: "short"),
                        LLMMessage(role: .user, content: String(repeating: "x", count: 50))]
        let trimmed = ChatService<ManualClock>.trimmed(messages, characterLimit: 10)
        #expect(trimmed.count == 1)
        #expect(trimmed.first?.content.count == 50)
    }
}
