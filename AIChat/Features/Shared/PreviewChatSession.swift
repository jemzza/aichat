#if DEBUG
import Foundation

/// `ChatSession` для превью и `-mockData` поверх фейков из `Mocks/`. Упрощённое
/// подобие `ChatService`: одна генерация на чат, черновик в памяти рассылается всем
/// подписчикам, в репозиторий пишется только финальный текст (без троттлинга и outbox).
///
/// Ответ из `PreviewData`, застрявший в `streaming`, «догенерируется» при первой
/// подписке на черновик этого чата.
@MainActor
final class PreviewChatSession: ChatSession {
    private struct Generation {
        let messageId: UUID
        var text: String
        let task: Task<Void, Never>
    }

    private let repository: any ChatRepository
    private let provider: FakeLLMProvider
    private let resumeProvider: FakeLLMProvider
    private let connectivity: any ConnectivityMonitoring
    private let now: () -> Date

    private var generations: [UUID: Generation] = [:]
    private var observers: [UUID: [UUID: AsyncStream<StreamingDraft?>.Continuation]] = [:]
    private var resumedChats: Set<UUID> = []

    init(
        repository: any ChatRepository,
        provider: FakeLLMProvider = FakeLLMProvider(script: .reply(PreviewChatSession.reply,
                                                                    tokenDelay: .milliseconds(60))),
        connectivity: any ConnectivityMonitoring = FakeConnectivityMonitor(isOnline: true),
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.provider = provider
        resumeProvider = FakeLLMProvider(script: .reply(Self.continuation, tokenDelay: .milliseconds(120)))
        self.connectivity = connectivity
        self.now = now
    }

    // MARK: ChatSession

    func draftUpdates(chatId: UUID) -> AsyncStream<StreamingDraft?> {
        let (stream, continuation) = AsyncStream.makeStream(of: StreamingDraft?.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[chatId, default: [:]][id] = continuation
        continuation.yield(draft(chatId: chatId))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[chatId]?[id] = nil }
        }
        resumeStreamingReplyIfNeeded(chatId: chatId)
        return stream
    }

    func send(_ text: String, inChat chatId: UUID?) async throws -> UUID {
        let date = now()
        let isOnline = connectivity.isOnline
        let chatId = chatId ?? UUID()
        let message = Message(chatId: chatId, role: .user, text: text,
                              status: isOnline ? .sent : .pending, createdAt: date)
        if try await chatExists(chatId) {
            try await repository.insertMessage(message)
        } else {
            let title = ChatTitle.make(from: text)
            try await repository.insertChat(Chat(id: chatId, title: title, createdAt: date, updatedAt: date),
                                            firstMessage: message)
        }
        guard isOnline else { return chatId }

        let reply = Message(chatId: chatId, role: .assistant, text: "", status: .streaming,
                            createdAt: date.addingTimeInterval(0.001))
        try await repository.insertMessage(reply)
        startGeneration(chatId: chatId, messageId: reply.id, initialText: "", provider: provider)
        return chatId
    }

    func stopGenerating(chatId: UUID) {
        generations[chatId]?.task.cancel()
    }

    func retry(assistantMessageId: UUID, inChat chatId: UUID) async throws {
        guard generations[chatId] == nil,
              try await repository.claimRetry(assistantMessageId: assistantMessageId)
        else { return }
        startGeneration(chatId: chatId, messageId: assistantMessageId, initialText: "", provider: provider)
    }

    /// Превью не показывает «Answer offline»: модель на устройстве — только в `ChatService`.
    var canAnswerOffline: Bool { false }

    func answerOffline(messageId: UUID, inChat chatId: UUID) async throws {}

    func deleteChat(id: UUID) async throws {
        generations[id]?.task.cancel()
        try await repository.deleteChat(id: id)
    }

    // MARK: Генерация

    private func draft(chatId: UUID) -> StreamingDraft? {
        generations[chatId].map { StreamingDraft(messageId: $0.messageId, text: $0.text) }
    }

    private func publishDraft(chatId: UUID) {
        let draft = draft(chatId: chatId)
        for continuation in observers[chatId, default: [:]].values { continuation.yield(draft) }
    }

    private func startGeneration(chatId: UUID, messageId: UUID, initialText: String, provider: FakeLLMProvider) {
        let repository = repository
        let task = Task { [weak self] in
            var text = initialText
            var failure: MessageFailure?
            do {
                for try await token in provider.streamReply(to: []) {
                    text += token
                    self?.generations[chatId]?.text = text
                    self?.publishDraft(chatId: chatId)
                }
            } catch {
                failure = MessageFailure(kind: (error as? LLMError)?.kind ?? .unknown)
            }
            // Отмена заканчивает поток без ошибки — «Stop» отличаем по `Task.isCancelled`.
            let status: MessageStatus = failure != nil ? .failed : Task.isCancelled ? .cancelled : .done
            // Сначала финальная запись, потом снимаем черновик — иначе мелькнёт старый текст.
            try? await repository.updateMessage(id: messageId, text: text, status: status, failure: failure)
            self?.generations[chatId] = nil
            self?.publishDraft(chatId: chatId)
        }
        generations[chatId] = Generation(messageId: messageId, text: initialText, task: task)
        publishDraft(chatId: chatId)
    }

    private func resumeStreamingReplyIfNeeded(chatId: UUID) {
        guard generations[chatId] == nil, resumedChats.insert(chatId).inserted else { return }
        Task {
            var messages = repository.observeMessages(chatId: chatId).makeAsyncIterator()
            guard generations[chatId] == nil,
                  let streaming = await messages.next()?.last(where: { $0.status == .streaming })
            else { return }
            startGeneration(chatId: chatId, messageId: streaming.id, initialText: streaming.text,
                            provider: resumeProvider)
        }
    }

    private func chatExists(_ chatId: UUID) async throws -> Bool {
        var chats = repository.observeChats().makeAsyncIterator()
        return await chats.next()?.contains { $0.id == chatId } ?? false
    }

    // MARK: Тексты фейка (содержимое переписки, не строки интерфейса)

    nonisolated static let continuation = """
         data races are caught at compile time instead of at runtime. \
        A lock only protects the code that remembers to take it; an actor protects *every* access.
        """

    nonisolated static let reply = """
        This is a **mock** reply streamed token by token. It is long enough to wrap \
        onto several lines, so you can watch the text appear smoothly, try *Stop* in \
        the middle, and scroll up while it keeps growing.
        """
}

extension ChatDependencies {
    static func preview(
        repository: any ChatRepository = PreviewData.repository(),
        connectivity: any ConnectivityMonitoring = FakeConnectivityMonitor(isOnline: true)
    ) -> ChatDependencies {
        ChatDependencies(
            repository: repository,
            session: PreviewChatSession(repository: repository, connectivity: connectivity),
            connectivity: connectivity,
            speech: FakeSpeechSynthesizer(),
            transcriber: FakeSpeechTranscriber(),
            modelName: "Groq · gpt-oss-120b"
        )
    }
}
#endif
