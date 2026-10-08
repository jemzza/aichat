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
    private(set) var stoppedChatIds: [UUID] = []

    func send(_ text: String, inChat chatId: UUID?) async throws -> UUID {
        sent.append((text, chatId))
        return try sendResult.get()
    }

    func stopGenerating(chatId: UUID) {
        stoppedChatIds.append(chatId)
    }

    private(set) var retriedMessageIds: [UUID] = []

    func retry(assistantMessageId: UUID, inChat chatId: UUID) async throws {
        retriedMessageIds.append(assistantMessageId)
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
        #expect(!viewModel.canRetry(done))
        #expect(!viewModel.canRetry(user))

        await viewModel.retry(done)
        await viewModel.retry(failed)
        #expect(session.retriedMessageIds == [failed.id])

        // Пока в чате идёт генерация, повторять нельзя.
        let streaming = Message(chatId: chat.id, role: .assistant, text: "", status: .streaming,
                                createdAt: .now.addingTimeInterval(3))
        try repository.insertMessage(streaming)
        try await waitUntil { viewModel.isGenerating }
        #expect(!viewModel.canRetry(failed))
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
}
