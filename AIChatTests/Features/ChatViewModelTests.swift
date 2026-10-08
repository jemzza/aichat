import Foundation
import Testing
@testable import AIChat

/// Управляемый вручную `ChatSession`: тест сам отдаёт черновики.
@MainActor
private final class ManualChatSession: ChatSession {
    private var continuations: [AsyncStream<StreamingDraft?>.Continuation] = []
    private(set) var deletedChatIds: [UUID] = []
    var subscriberCount: Int { continuations.count }

    func draftUpdates(chatId: UUID) -> AsyncStream<StreamingDraft?> {
        let (stream, continuation) = AsyncStream<StreamingDraft?>.makeStream()
        continuation.yield(nil)
        continuations.append(continuation)
        return stream
    }

    func send(_ draft: StreamingDraft?) {
        for continuation in continuations { continuation.yield(draft) }
    }

    func deleteChat(id: UUID) async throws {
        deletedChatIds.append(id)
    }

    var sendResult: Result<UUID, Error> = .success(UUID())
    private(set) var sent: [(text: String, chatId: UUID?)] = []
    private(set) var sentImages: [[ImageAttachment]] = []
    private(set) var stoppedChatIds: [UUID] = []

    func send(_ text: String, images: [ImageAttachment], inChat chatId: UUID?) async throws -> UUID {
        sent.append((text, chatId))
        sentImages.append(images)
        return try sendResult.get()
    }

    func stopGenerating(chatId: UUID) {
        stoppedChatIds.append(chatId)
    }

    private(set) var retriedMessageIds: [UUID] = []

    func retry(assistantMessageId: UUID, inChat chatId: UUID) async throws {
        retriedMessageIds.append(assistantMessageId)
    }

    var canAnswerOffline = false
    private(set) var offlineAnsweredMessageIds: [UUID] = []

    func answerOffline(messageId: UUID, inChat chatId: UUID) async throws {
        offlineAnsweredMessageIds.append(messageId)
    }
}

private struct SendFailed: Error {}

@MainActor
struct ChatViewModelTests {
    private let chat = Chat(id: UUID(), title: "Chat", createdAt: .now, updatedAt: .now)

    private func makeMessages() -> (user: Message, reply: Message) {
        let user = Message(chatId: chat.id, role: .user, text: "Hi", status: .sent, createdAt: .now)
        let reply = Message(chatId: chat.id, role: .assistant, text: "Hel", status: .streaming,
                            createdAt: .now.addingTimeInterval(1))
        return (user, reply)
    }

    @Test func newChatIsLoadedAndEmpty() async {
        let repository = InMemoryChatRepository()
        let viewModel = ChatViewModel(chatId: nil, repository: repository, session: ManualChatSession())

        await viewModel.observeMessages()
        await viewModel.observeDraft()

        #expect(viewModel.hasLoaded)
        #expect(viewModel.displayedMessages.isEmpty)
        #expect(!viewModel.showsScrollToBottomButton)
    }

    @Test func draftOverlaysStreamingReply() async throws {
        let (user, reply) = makeMessages()
        let repository = InMemoryChatRepository(chats: [chat], messages: [user, reply])
        let session = ManualChatSession()
        let viewModel = ChatViewModel(chatId: chat.id, repository: repository, session: session)
        let messagesTask = Task { await viewModel.observeMessages() }
        let draftTask = Task { await viewModel.observeDraft() }
        defer { messagesTask.cancel(); draftTask.cancel() }

        try await waitUntil { viewModel.messages.count == 2 && session.subscriberCount == 1 }
        #expect(viewModel.displayedMessages.map(\.text) == ["Hi", "Hel"])

        session.send(StreamingDraft(messageId: reply.id, text: "Hello, wor"))
        try await waitUntil { viewModel.displayedMessages.last?.text == "Hello, wor" }
        // Сообщение пользователя черновик не трогает.
        #expect(viewModel.displayedMessages.first?.text == "Hi")
    }

    /// Ответ уже записан финально, а черновик ещё не сброшен — показываем текст из базы.
    @Test func draftIgnoredOnceReplyIsNoLongerStreaming() async throws {
        let (user, reply) = makeMessages()
        let repository = InMemoryChatRepository(chats: [chat], messages: [user, reply])
        let session = ManualChatSession()
        let viewModel = ChatViewModel(chatId: chat.id, repository: repository, session: session)
        let messagesTask = Task { await viewModel.observeMessages() }
        let draftTask = Task { await viewModel.observeDraft() }
        defer { messagesTask.cancel(); draftTask.cancel() }
        try await waitUntil { session.subscriberCount == 1 }

        session.send(StreamingDraft(messageId: reply.id, text: "Hello, wor"))
        try await waitUntil { viewModel.draft != nil }
        try repository.updateMessage(id: reply.id, text: "Hello, world!", status: .done, failure: nil)

        try await waitUntil { viewModel.displayedMessages.last?.text == "Hello, world!" }
    }

    @Test func scrollToBottomButtonFollowsUserScrolling() async throws {
        let (user, reply) = makeMessages()
        let repository = InMemoryChatRepository(chats: [chat], messages: [user, reply])
        let viewModel = ChatViewModel(chatId: chat.id, repository: repository, session: ManualChatSession())
        let messagesTask = Task { await viewModel.observeMessages() }
        defer { messagesTask.cancel() }
        try await waitUntil { viewModel.hasLoaded }

        #expect(viewModel.isPinnedToBottom)
        #expect(!viewModel.showsScrollToBottomButton)

        viewModel.userScrolled(isAtBottom: false)
        #expect(!viewModel.isPinnedToBottom)
        #expect(viewModel.showsScrollToBottomButton)

        viewModel.scrollToBottomTapped()
        #expect(viewModel.isPinnedToBottom)
        #expect(!viewModel.showsScrollToBottomButton)
    }

    // MARK: Поле ввода

    @Test func canSendOnlyNonBlankTextWhileIdle() async throws {
        let (user, reply) = makeMessages()
        let repository = InMemoryChatRepository(chats: [chat], messages: [user, reply])
        let viewModel = ChatViewModel(chatId: chat.id, repository: repository, session: ManualChatSession())
        let messagesTask = Task { await viewModel.observeMessages() }
        defer { messagesTask.cancel() }
        try await waitUntil { viewModel.hasLoaded }

        viewModel.inputText = "Next question"
        #expect(viewModel.isGenerating)
        #expect(!viewModel.canSend)

        try repository.updateMessage(id: reply.id, text: "Hello", status: .done, failure: nil)
        try await waitUntil { !viewModel.isGenerating }
        #expect(viewModel.canSend)

        viewModel.inputText = "  \n "
        #expect(!viewModel.canSend)
    }

    // MARK: Фото

    @Test func attachedPhotosAreSentAndCleared() async {
        let session = ManualChatSession()
        let viewModel = ChatViewModel(chatId: chat.id, repository: InMemoryChatRepository(chats: [chat]),
                                      session: session, prepareImage: { Data($0.reversed()) })
        #expect(viewModel.supportsImages)
        #expect(!viewModel.canSend)

        await viewModel.attachImages([Data([1, 2]), nil])
        #expect(viewModel.attachments.map(\.jpegData) == [Data([2, 1])])
        #expect(viewModel.attachmentFailed)
        // Только фото, без текста — уже можно отправить.
        #expect(viewModel.canSend)

        await viewModel.send()
        #expect(session.sent.map(\.text) == [""])
        #expect(session.sentImages.map { $0.map(\.jpegData) } == [[Data([2, 1])]])
        #expect(viewModel.attachments.isEmpty)
    }

    @Test func photosAreLimitedPerMessageAndRemovable() async {
        let viewModel = ChatViewModel(chatId: nil, repository: InMemoryChatRepository(), session: ManualChatSession(),
                                      prepareImage: { $0 })
        await viewModel.attachImages((0..<5).map { Data([UInt8($0)]) })
        #expect(viewModel.attachments.count == ImageAttachment.maxPerMessage)
        #expect(viewModel.remainingAttachmentSlots == 0)
        #expect(!viewModel.canAttachImages)

        viewModel.removeAttachment(id: viewModel.attachments[0].id)
        #expect(viewModel.attachments.map(\.jpegData) == [Data([1]), Data([2])])
        #expect(viewModel.canAttachImages)
    }

    @Test func withoutPreparerThereIsNoPhotoButton() async {
        let viewModel = ChatViewModel(chatId: nil, repository: InMemoryChatRepository(), session: ManualChatSession())
        #expect(!viewModel.supportsImages)
        await viewModel.attachImages([Data([1])])
        #expect(viewModel.attachments.isEmpty)
    }

    @Test func failedSendRestoresPhotos() async {
        let session = ManualChatSession()
        session.sendResult = .failure(SendFailed())
        let viewModel = ChatViewModel(chatId: chat.id, repository: InMemoryChatRepository(chats: [chat]),
                                      session: session, prepareImage: { $0 })
        await viewModel.attachImages([Data([7])])
        await viewModel.send()
        #expect(viewModel.sendFailed)
        #expect(viewModel.attachments.map(\.jpegData) == [Data([7])])
    }

    @Test func sendFromNewChatAdoptsCreatedChat() async {
        let session = ManualChatSession()
        let createdId = UUID()
        session.sendResult = .success(createdId)
        var reported: [UUID] = []
        let viewModel = ChatViewModel(chatId: nil, repository: InMemoryChatRepository(), session: session,
                                      onChatCreated: { reported.append($0) })

        viewModel.inputText = "  Hello there \n"
        await viewModel.send()

        #expect(session.sent.map(\.text) == ["Hello there"])
        #expect(session.sent.first?.chatId == nil)
        #expect(viewModel.chatId == createdId)
        #expect(reported == [createdId])
        #expect(viewModel.inputText.isEmpty)
    }

    @Test func sendToExistingChatDoesNotReportCreation() async {
        let session = ManualChatSession()
        session.sendResult = .success(chat.id)
        var reported: [UUID] = []
        let viewModel = ChatViewModel(chatId: chat.id, repository: InMemoryChatRepository(), session: session,
                                      onChatCreated: { reported.append($0) })

        viewModel.inputText = "Hi"
        await viewModel.send()

        #expect(session.sent.first?.chatId == chat.id)
        #expect(reported.isEmpty)
    }

    @Test func failedSendRestoresText() async {
        let session = ManualChatSession()
        session.sendResult = .failure(SendFailed())
        let viewModel = ChatViewModel(chatId: nil, repository: InMemoryChatRepository(), session: session)

        viewModel.inputText = "Keep me"
        await viewModel.send()

        #expect(viewModel.inputText == "Keep me")
        #expect(viewModel.sendFailed)
        #expect(viewModel.chatId == nil)
    }

    @Test func stopIsForwardedOnlyWhileGenerating() async throws {
        let (user, reply) = makeMessages()
        let repository = InMemoryChatRepository(chats: [chat], messages: [user, reply])
        let session = ManualChatSession()
        let viewModel = ChatViewModel(chatId: chat.id, repository: repository, session: session)
        let messagesTask = Task { await viewModel.observeMessages() }
        defer { messagesTask.cancel() }
        try await waitUntil { viewModel.hasLoaded }

        viewModel.stop()
        #expect(session.stoppedChatIds == [chat.id])

        try repository.updateMessage(id: reply.id, text: "Hel", status: .cancelled, failure: nil)
        try await waitUntil { !viewModel.isGenerating }
        viewModel.stop()
        #expect(session.stoppedChatIds == [chat.id])
    }

    // MARK: Действия с ответом

    @Test func retryOnlyForRetryableRepliesWhileIdle() async throws {
        let user = Message(chatId: chat.id, role: .user, text: "Hi", status: .sent, createdAt: .now)
        let failed = Message(chatId: chat.id, role: .assistant, text: "", status: .failed,
                             failure: MessageFailure(kind: .server), createdAt: .now.addingTimeInterval(1))
        let done = Message(chatId: chat.id, role: .assistant, text: "Ok", status: .done,
                           createdAt: .now.addingTimeInterval(2))
        let repository = InMemoryChatRepository(chats: [chat], messages: [user, failed, done])
        let session = ManualChatSession()
        let viewModel = ChatViewModel(chatId: chat.id, repository: repository, session: session)
        let messagesTask = Task { await viewModel.observeMessages() }
        defer { messagesTask.cancel() }
        try await waitUntil { viewModel.messages.count == 3 }

        #expect(viewModel.canRetry(failed))
        // `done` — последний ответ в чате: его можно перегенерировать.
        #expect(viewModel.canRetry(done))
        #expect(!viewModel.canRetry(user))

        await viewModel.retry(failed)
        await viewModel.retry(done)
        #expect(session.retriedMessageIds == [failed.id, done.id])

        // Пока в чате идёт генерация, повторять нельзя.
        let streaming = Message(chatId: chat.id, role: .assistant, text: "", status: .streaming,
                                createdAt: .now.addingTimeInterval(3))
        try repository.insertMessage(streaming)
        try await waitUntil { viewModel.isGenerating }
        #expect(!viewModel.canRetry(failed))
    }

    /// «Answer offline» — только у первого `pending` и только когда сервис это разрешает.
    @Test func answerOfflineOnlyForFirstPendingWhenAvailable() async throws {
        let first = Message(chatId: chat.id, role: .user, text: "One", status: .pending, createdAt: .now)
        let second = Message(chatId: chat.id, role: .user, text: "Two", status: .pending,
                             createdAt: .now.addingTimeInterval(1))
        let repository = InMemoryChatRepository(chats: [chat], messages: [first, second])
        let session = ManualChatSession()
        let viewModel = ChatViewModel(chatId: chat.id, repository: repository, session: session)
        let messagesTask = Task { await viewModel.observeMessages() }
        defer { messagesTask.cancel() }
        try await waitUntil { viewModel.messages.count == 2 }

        #expect(!viewModel.canAnswerOffline(first))
        session.canAnswerOffline = true
        #expect(viewModel.canAnswerOffline(first))
        #expect(!viewModel.canAnswerOffline(second))

        await viewModel.answerOffline(second)
        await viewModel.answerOffline(first)
        #expect(session.offlineAnsweredMessageIds == [first.id])
    }

    @Test func copyWritesTextAndMarksMessage() {
        var clipboard: [String] = []
        let viewModel = ChatViewModel(chatId: chat.id, repository: InMemoryChatRepository(),
                                      session: ManualChatSession(), copyToClipboard: { clipboard.append($0) })
        let reply = Message(chatId: chat.id, role: .assistant, text: "Answer", status: .done, createdAt: .now)
        let empty = Message(chatId: chat.id, role: .assistant, text: "", status: .failed, createdAt: .now)

        viewModel.copy(empty)
        #expect(clipboard.isEmpty)
        #expect(viewModel.copiedMessageId == nil)

        viewModel.copy(reply)
        #expect(clipboard == ["Answer"])
        #expect(viewModel.copiedMessageId == reply.id)

        viewModel.copyText("let x = 1")
        viewModel.copyText("")
        #expect(clipboard == ["Answer", "let x = 1"])
    }

    // MARK: Пустой экран

    @Test func emptyStateOnlyForChatWithoutMessages() async throws {
        let newChat = ChatViewModel(chatId: nil, repository: InMemoryChatRepository(), session: ManualChatSession())
        #expect(newChat.showsEmptyState)

        let (user, reply) = makeMessages()
        let repository = InMemoryChatRepository(chats: [chat], messages: [user, reply])
        let existing = ChatViewModel(chatId: chat.id, repository: repository, session: ManualChatSession())
        #expect(!existing.showsEmptyState)
        let messagesTask = Task { await existing.observeMessages() }
        defer { messagesTask.cancel() }
        try await waitUntil { existing.hasLoaded }
        #expect(!existing.showsEmptyState)
    }

    @Test func greetingFollowsInjectedClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let afternoon = Date(timeIntervalSince1970: 13 * 3600)
        let viewModel = ChatViewModel(chatId: nil, repository: InMemoryChatRepository(), session: ManualChatSession(),
                                      now: { afternoon }, calendar: calendar)
        #expect(viewModel.greeting == .afternoon)
    }

    @Test func suggestionSendsPromptAndKeepsTypedText() async {
        let session = ManualChatSession()
        let createdId = UUID()
        session.sendResult = .success(createdId)
        let viewModel = ChatViewModel(chatId: nil, repository: InMemoryChatRepository(), session: session)
        viewModel.inputText = "draft"
        let suggestion = Suggestion.all[0]

        await viewModel.send(suggestion: suggestion)

        #expect(session.sent.map(\.text) == [String(localized: suggestion.prompt)])
        #expect(viewModel.inputText == "draft")
        #expect(viewModel.chatId == createdId)
        // Подписка на созданный чат ещё не отдала сообщения — приветствие не мигает.
        #expect(!viewModel.showsEmptyState)
    }

    /// Перегенерировать можно только последний ответ: на старые опираются следующие сообщения.
    @Test func regenerateOnlyTheLatestReply() async throws {
        let question = Message(chatId: chat.id, role: .user, text: "Q1", status: .sent, createdAt: .now)
        let oldAnswer = Message(chatId: chat.id, role: .assistant, text: "A1", status: .done,
                                createdAt: .now.addingTimeInterval(1))
        let followUp = Message(chatId: chat.id, role: .user, text: "Q2", status: .sent,
                               createdAt: .now.addingTimeInterval(2))
        let latest = Message(chatId: chat.id, role: .assistant, text: "A2", status: .done,
                             createdAt: .now.addingTimeInterval(3))
        let repository = InMemoryChatRepository(chats: [chat], messages: [question, oldAnswer, followUp, latest])
        let session = ManualChatSession()
        let viewModel = ChatViewModel(chatId: chat.id, repository: repository, session: session)
        let messagesTask = Task { await viewModel.observeMessages() }
        defer { messagesTask.cancel() }
        try await waitUntil { viewModel.messages.count == 4 }

        #expect(!viewModel.canRetry(oldAnswer))
        #expect(viewModel.canRetry(latest))

        await viewModel.retry(oldAnswer)
        await viewModel.retry(latest)
        #expect(session.retriedMessageIds == [latest.id])
    }

    // MARK: Озвучка

    @Test func readAloudSpeaksCleanTextAndTracksPlayback() async throws {
        let reply = Message(chatId: chat.id, role: .assistant, text: "## Title\n```\ncode\n```", status: .done,
                            createdAt: .now)
        let repository = InMemoryChatRepository(chats: [chat], messages: [reply])
        let speech = FakeSpeechSynthesizer()
        let viewModel = ChatViewModel(chatId: chat.id, repository: repository, session: ManualChatSession(),
                                      speech: speech)
        let messagesTask = Task { await viewModel.observeMessages() }
        let speechTask = Task { await viewModel.observeSpeech() }
        defer { messagesTask.cancel(); speechTask.cancel() }
        try await waitUntil { viewModel.hasLoaded }

        #expect(viewModel.canReadAloud(reply))
        viewModel.toggleReadAloud(reply)
        #expect(speech.spoken.map(\.text) == ["Title."])
        try await waitUntil { viewModel.speakingMessageId == reply.id }

        speech.finish()
        try await waitUntil { viewModel.speakingMessageId == nil }
    }

    @Test func secondTapStopsReading() async throws {
        let reply = Message(chatId: chat.id, role: .assistant, text: "Hello", status: .done, createdAt: .now)
        let speech = FakeSpeechSynthesizer()
        let viewModel = ChatViewModel(chatId: chat.id, repository: InMemoryChatRepository(),
                                      session: ManualChatSession(), speech: speech)
        let speechTask = Task { await viewModel.observeSpeech() }
        defer { speechTask.cancel() }

        viewModel.toggleReadAloud(reply)
        try await waitUntil { viewModel.speakingMessageId == reply.id }
        viewModel.toggleReadAloud(reply)

        #expect(speech.stopCount == 1)
        try await waitUntil { viewModel.speakingMessageId == nil }
    }

    @Test func cannotReadStreamingCodeOnlyOrWithoutSynthesizer() {
        let streaming = Message(chatId: chat.id, role: .assistant, text: "Hel", status: .streaming, createdAt: .now)
        let codeOnly = Message(chatId: chat.id, role: .assistant, text: "```\nx\n```", status: .done, createdAt: .now)
        let done = Message(chatId: chat.id, role: .assistant, text: "Hi", status: .done, createdAt: .now)
        let withSpeech = ChatViewModel(chatId: chat.id, repository: InMemoryChatRepository(),
                                       session: ManualChatSession(), speech: FakeSpeechSynthesizer())
        let withoutSpeech = ChatViewModel(chatId: chat.id, repository: InMemoryChatRepository(),
                                          session: ManualChatSession())

        #expect(!withSpeech.canReadAloud(streaming))
        #expect(!withSpeech.canReadAloud(codeOnly))
        #expect(withSpeech.canReadAloud(done))
        #expect(!withoutSpeech.canReadAloud(done))
    }
}

