#if DEBUG
import Foundation

/// `ChatSession` для превью и `-mockData` поверх фейков из `Mocks/`.
/// Ответ в статусе `streaming` «догенерирует» `FakeLLMProvider`: черновик растёт
/// по токенам, в конце текст пишется в репозиторий со статусом `done`.
@MainActor
final class PreviewChatSession: ChatSession {
    private let repository: any ChatRepository
    private let provider: FakeLLMProvider

    init(
        repository: any ChatRepository,
        provider: FakeLLMProvider = FakeLLMProvider(script: .reply(PreviewChatSession.continuation,
                                                                    tokenDelay: .milliseconds(120)))
    ) {
        self.repository = repository
        self.provider = provider
    }

    func draftUpdates(chatId: UUID) -> AsyncStream<StreamingDraft?> {
        let repository = repository
        let provider = provider
        return AsyncStream { continuation in
            let task = Task {
                var messages = repository.observeMessages(chatId: chatId).makeAsyncIterator()
                guard let streaming = await messages.next()?.first(where: { $0.status == .streaming }) else {
                    continuation.yield(nil)
                    continuation.finish()
                    return
                }
                var text = streaming.text
                continuation.yield(StreamingDraft(messageId: streaming.id, text: text))
                do {
                    for try await token in provider.streamReply(to: []) {
                        text += token
                        continuation.yield(StreamingDraft(messageId: streaming.id, text: text))
                    }
                    if !Task.isCancelled {
                        try await repository.updateMessage(id: streaming.id, text: text, status: .done, failure: nil)
                    }
                } catch {
                    // Превью: ошибки фейка не показываем, черновик просто исчезает.
                }
                continuation.yield(nil)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func deleteChat(id: UUID) async throws {
        try await repository.deleteChat(id: id)
    }

    /// Продолжение ответа из `PreviewData` (содержимое переписки, не строка интерфейса).
    nonisolated static let continuation = """
         data races are caught at compile time instead of at runtime. \
        A lock only protects the code that remembers to take it; an actor protects *every* access.
        """
}

extension ChatDependencies {
    static func preview(repository: any ChatRepository = PreviewData.repository()) -> ChatDependencies {
        ChatDependencies(
            repository: repository,
            session: PreviewChatSession(repository: repository),
            modelName: "Groq · gpt-oss-120b"
        )
    }
}
#endif
