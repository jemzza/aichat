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
}

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
}
