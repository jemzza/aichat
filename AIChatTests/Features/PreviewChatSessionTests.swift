import Foundation
import Testing
@testable import AIChat

/// `PreviewChatSession` питает превью и `-mockData`, поэтому проверяем, что он
/// ведёт себя как описано в `ChatSession` (и как будет вести себя `ChatService`).
@MainActor
struct PreviewChatSessionTests {
    @Test func sendToNewChatCreatesChatAndStreamsReply() async throws {
        let repository = InMemoryChatRepository()
        let provider = FakeLLMProvider(script: .reply("Hi there", tokenDelay: .zero))
        let session = PreviewChatSession(repository: repository, provider: provider)

        let chatId = try await session.send("Hello", inChat: nil)

        let chats = try await firstValue(of: repository.observeChats())
        #expect(chats.map(\.title) == ["Hello"])
        let messages = try await firstValue(of: repository.observeMessages(chatId: chatId)) {
            $0.last?.status == .done
        }
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages.map(\.status) == [.sent, .done])
        #expect(messages.last?.text == "Hi there")
    }

    @Test func offlineSendLeavesPendingMessageWithoutReply() async throws {
        let repository = InMemoryChatRepository()
        let session = PreviewChatSession(repository: repository,
                                         connectivity: FakeConnectivityMonitor(isOnline: false))

        let chatId = try await session.send("Hello", inChat: nil)

        let messages = try await firstValue(of: repository.observeMessages(chatId: chatId))
        #expect(messages.map(\.status) == [.pending])
    }

    @Test func stopKeepsPartialTextAsCancelled() async throws {
        let repository = InMemoryChatRepository()
        let provider = FakeLLMProvider(script: .reply("one two three four five six", tokenDelay: .milliseconds(40)))
        let session = PreviewChatSession(repository: repository, provider: provider)
        let chatId = try await session.send("Count", inChat: nil)

        var drafts = session.draftUpdates(chatId: chatId).makeAsyncIterator()
        while let draft = await drafts.next() {
            if let draft, draft.text.hasPrefix("one two") { break }
        }
        session.stopGenerating(chatId: chatId)

        let messages = try await firstValue(of: repository.observeMessages(chatId: chatId)) {
            $0.last?.status == .cancelled
        }
        let text = try #require(messages.last?.text)
        #expect(text.hasPrefix("one two"))
        #expect(text != "one two three four five six")
    }

    @Test func secondMessageGoesToSameChat() async throws {
        let repository = InMemoryChatRepository()
        let provider = FakeLLMProvider(script: .reply("Ok", tokenDelay: .zero))
        let session = PreviewChatSession(repository: repository, provider: provider)

        let chatId = try await session.send("First", inChat: nil)
        _ = try await firstValue(of: repository.observeMessages(chatId: chatId)) { $0.last?.status == .done }
        let sameId = try await session.send("Second", inChat: chatId)

        #expect(sameId == chatId)
        let messages = try await firstValue(of: repository.observeMessages(chatId: chatId)) {
            $0.count == 4 && $0.last?.status == .done
        }
        #expect(messages.filter { $0.role == .user }.map(\.text) == ["First", "Second"])
        let chats = try await firstValue(of: repository.observeChats())
        #expect(chats.count == 1)
    }
}
