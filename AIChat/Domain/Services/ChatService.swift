import Foundation

/// Логика чата: отправка, генерация ответа, «Stop», «Retry», outbox, удаление.
///
/// - База — единственный источник правды; сервис только пишет в неё через `ChatRepository`.
/// - Живой черновик ответа — в памяти (`draftUpdates`), в базу текст пишется не чаще
///   `writeInterval` и один раз в конце (исключение из offline-first, см. docs/task.md).
/// - Генерацией владеет сервис (живёт в `AppContainer`), а не экран: уход с экрана её не отменяет.
@MainActor
final class ChatService<C: Clock>: ChatSession where C.Duration == Duration {
    struct Configuration: Sendable {
        /// Сколько последних сообщений истории идёт в запрос.
        var historyLimit = 20
        /// Обрезка контекста по символам (≈2K токенов) — экономия лимита Groq.
        var contextCharacterLimit = 6000
        /// Сколько фото (самых свежих) идёт в запрос — лимит vision-модели Groq.
        var imageLimit = ImageAttachment.maxPerMessage
        /// Как часто писать стримящийся текст в базу.
        var writeInterval: Duration = .milliseconds(500)
    }

    private struct Generation {
        let messageId: UUID
        var text = ""
        var task: Task<Void, Never>?
        /// Система забрала фоновое время — итог `interrupted`, а не `cancelled`.
        var interruptedBySystem = false
    }

    private let repository: any ChatRepository
    private let provider: any LLMProvider
    /// Модель на устройстве для «Answer offline»; `nil` — iOS 18 или нет Foundation Models.
    private let onDeviceProvider: (any OnDeviceLLMProvider)?
    private let connectivity: any ConnectivityMonitoring
    private let backgroundTasks: (any BackgroundTaskScheduling)?
    /// Уведомления о готовом ответе и отправленном outbox.
    private let eventHandler: (any ChatEventHandling)?
    private let clock: C
    private let now: () -> Date
    private let configuration: Configuration

    /// Не больше одной генерации на чат.
    private var generations: [UUID: Generation] = [:]
    private var draftObservers: [UUID: [UUID: AsyncStream<StreamingDraft?>.Continuation]] = [:]
    private var isProcessingOutbox = false
    private var isOutboxRerunRequested = false

    init(
        repository: any ChatRepository,
        provider: any LLMProvider,
        onDeviceProvider: (any OnDeviceLLMProvider)? = nil,
        connectivity: any ConnectivityMonitoring,
        backgroundTasks: (any BackgroundTaskScheduling)? = nil,
        eventHandler: (any ChatEventHandling)? = nil,
        clock: C,
        now: @escaping () -> Date = Date.init,
        configuration: Configuration = Configuration()
    ) {
        self.repository = repository
        self.provider = provider
        self.onDeviceProvider = onDeviceProvider
        self.connectivity = connectivity
        self.backgroundTasks = backgroundTasks
        self.eventHandler = eventHandler
        self.clock = clock
        self.now = now
        self.configuration = configuration
    }

    /// Идёт ли сейчас генерация в чате.
    func isGenerating(chatId: UUID) -> Bool {
        generations[chatId] != nil
    }

    // MARK: Жизненный цикл приложения

    /// Следит за сетью, пока жива задача вызывающего: первое значение — запуск,
    /// дальше каждое появление сети отправляет outbox.
    func run() async {
        for await isOnline in connectivity.updates() where isOnline {
            await processOutbox()
        }
    }

    /// Возврат в foreground — ещё один повод отправить outbox.
    func appDidBecomeActive() {
        Task { await processOutbox() }
    }

    // MARK: ChatSession

    func draftUpdates(chatId: UUID) -> AsyncStream<StreamingDraft?> {
        let (stream, continuation) = AsyncStream.makeStream(of: StreamingDraft?.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        draftObservers[chatId, default: [:]][id] = continuation
        continuation.yield(draft(chatId: chatId))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.draftObservers[chatId]?[id] = nil }
        }
        return stream
    }

    func send(_ text: String, images: [ImageAttachment], inChat chatId: UUID?) async throws -> UUID {
        let date = now()
        let chatId = chatId ?? UUID()
        // Всегда сначала `pending`: переход в `sent` вместе с ответом — атомарный
        // `claimPending`, тот же путь, что у outbox, поэтому двойной отправки нет.
        let message = Message(chatId: chatId, role: .user, text: text, status: .pending,
                              images: Array(images.prefix(ImageAttachment.maxPerMessage)), createdAt: date)
        if try await chatExists(chatId) {
            try await repository.insertMessage(message)
        } else {
            let chat = Chat(id: chatId, title: ChatTitle.make(from: text), createdAt: date, updatedAt: date)
            try await repository.insertChat(chat, firstMessage: message)
        }
        if connectivity.isOnline, generations[chatId] == nil {
            _ = try await claimAndGenerate(message)
        }
        return chatId
    }

    func stopGenerating(chatId: UUID) {
        generations[chatId]?.task?.cancel()
    }

    func retry(assistantMessageId: UUID, inChat chatId: UUID) async throws {
        guard generations[chatId] == nil,
              try await repository.claimRetry(assistantMessageId: assistantMessageId),
              // Пока ждали базу, мог стартовать outbox в этом же чате.
              generations[chatId] == nil
        else { return }
        startGeneration(chatId: chatId, messageId: assistantMessageId, provider: provider)
    }

    var canAnswerOffline: Bool {
        !connectivity.isOnline && onDeviceProvider?.isAvailable == true
    }

    func answerOffline(messageId: UUID, inChat chatId: UUID) async throws {
        guard canAnswerOffline, let onDeviceProvider, generations[chatId] == nil,
              let message = try await repository.pendingMessages().first(where: { $0.id == messageId }),
              // Модель на устройстве фото не видит — отвечать на него вслепую незачем.
              message.images.isEmpty,
              // Пока ждали базу, могла появиться сеть (outbox) или начаться другая генерация.
              canAnswerOffline, generations[chatId] == nil
        else { return }
        _ = try await claimAndGenerate(message, provider: onDeviceProvider)
    }

    func deleteChat(id: UUID) async throws {
        // Запоздалая запись ответа получит `MessageNotFound` — её глотаем в `generate`.
        generations[id]?.task?.cancel()
        try await repository.deleteChat(id: id)
    }

    func deleteAll() async throws {
        // Запоздалые записи отменённых генераций получат `MessageNotFound` — их глотаем в `generate`.
        for generation in generations.values { generation.task?.cancel() }
        try await repository.deleteAll()
    }

    // MARK: Outbox

    /// Отправляет `pending` по очереди: следующий — после того, как ответ на предыдущий готов.
    /// Повторные вызовы во время работы не запускают второй проход параллельно.
    /// Если что-то ушло — одно событие `queuedMessagesDidSend` на проход.
    func processOutbox() async {
        guard !isProcessingOutbox else {
            isOutboxRerunRequested = true
            return
        }
        isProcessingOutbox = true
        let sent = await drainOutbox()
        isProcessingOutbox = false
        if sent > 0 { await eventHandler?.queuedMessagesDidSend(count: sent) }
    }

    /// - Returns: сколько `pending` забрано и отправлено.
    private func drainOutbox() async -> Int {
        var sent = 0
        repeat {
            isOutboxRerunRequested = false
            guard connectivity.isOnline, let pending = try? await repository.pendingMessages() else { return sent }
            for message in pending {
                guard connectivity.isOnline else { return sent }
                // Чат занят генерацией — его сообщения уйдут, когда она закончится
                // (`finishGeneration` снова запускает outbox).
                guard generations[message.chatId] == nil else { continue }
                guard let task = try? await claimAndGenerate(message) else { continue }
                sent += 1
                await task.value
            }
        } while isOutboxRerunRequested
        return sent
    }

    /// Атомарно `pending` → `sent` + ответ `streaming`; `nil` — сообщение уже забрали.
    private func claimAndGenerate(
        _ message: Message,
        provider: (any LLMProvider)? = nil
    ) async throws -> Task<Void, Never>? {
        // Ответ сразу после своего вопроса, даже если за ним уже стоят другие `pending`.
        let reply = Message(chatId: message.chatId, role: .assistant, text: "", status: .streaming,
                            createdAt: message.createdAt.addingTimeInterval(0.001))
        guard try await repository.claimPending(messageId: message.id, reply: reply) else { return nil }
        return startGeneration(chatId: message.chatId, messageId: reply.id, provider: provider ?? self.provider)
    }

    // MARK: Генерация

    @discardableResult
    private func startGeneration(chatId: UUID, messageId: UUID, provider: any LLMProvider) -> Task<Void, Never> {
        generations[chatId] = Generation(messageId: messageId)
        let task = Task { [weak self] () -> Void in
            await self?.generate(chatId: chatId, messageId: messageId, provider: provider)
        }
        generations[chatId]?.task = task
        publishDraft(chatId: chatId)
        return task
    }

    private func generate(chatId: UUID, messageId: UUID, provider: any LLMProvider) async {
        let backgroundToken = backgroundTasks?.beginTask { [weak self] in
            self?.generations[chatId]?.interruptedBySystem = true
            self?.generations[chatId]?.task?.cancel()
        }
        defer {
            if let backgroundToken { backgroundTasks?.endTask(backgroundToken) }
        }

        var text = ""
        var failure: MessageFailure?
        var lastWrite: C.Instant?
        do {
            let context = try await context(chatId: chatId, before: messageId)
            for try await delta in provider.streamReply(to: context) {
                text += delta
                generations[chatId]?.text = text
                publishDraft(chatId: chatId)
                let instant = clock.now
                if lastWrite.map({ $0.duration(to: instant) >= configuration.writeInterval }) ?? true {
                    lastWrite = instant
                    try await repository.updateMessage(id: messageId, text: text, status: .streaming, failure: nil)
                }
            }
        } catch is MessageNotFound {
            // Чат удалили во время генерации — писать некуда.
            finishGeneration(chatId: chatId, messageId: messageId)
            return
        } catch let error as LLMError {
            failure = MessageFailure(kind: error.kind, retryAt: error.retryAfter.map { retryDate(after: $0) })
        } catch {
            // Отмена (в т.ч. `CancellationError` из базы) — это «Stop», а не ошибка.
            if !Task.isCancelled { failure = MessageFailure(kind: .unknown) }
        }

        let status: MessageStatus
        if generations[chatId]?.interruptedBySystem == true {
            status = .interrupted
            failure = nil
        } else if failure != nil {
            status = .failed
        } else {
            status = Task.isCancelled ? .cancelled : .done
        }
        // Финальная запись — в отдельной задаче: отменённая генерация («Stop») сама
        // записать уже не может, а частичный текст должен сохраниться.
        let repository = repository
        let finalFailure = failure
        let saved = await Task {
            do {
                try await repository.updateMessage(id: messageId, text: text, status: status, failure: finalFailure)
                return true
            } catch {
                // `MessageNotFound` — чат удалён; прочее — ответ останется `streaming`
                // и при следующем запуске станет `interrupted`.
                return false
            }
        }.value
        // Уведомление — пока фоновое время ещё наше (`endTask` — в `defer`).
        if saved, status == .done, !text.isEmpty {
            await eventHandler?.replyDidFinish(chatId: chatId, text: text)
        }
        finishGeneration(chatId: chatId, messageId: messageId)
    }

    private func finishGeneration(chatId: UUID, messageId: UUID) {
        guard generations[chatId]?.messageId == messageId else { return }
        generations[chatId] = nil
        publishDraft(chatId: chatId)
        // Пока шла генерация, в чате могли накопиться `pending`.
        if connectivity.isOnline {
            Task { await processOutbox() }
        }
    }

    // MARK: Контекст

    private func context(chatId: UUID, before messageId: UUID) async throws -> [LLMMessage] {
        let history = try await repository.history(chatId: chatId, before: messageId,
                                                   limit: configuration.historyLimit)
        let messages = history.map { message in
            LLMMessage(role: message.role == .user ? .user : .assistant, content: message.text,
                       images: message.images.map(\.jpegData))
        }
        let trimmed = Self.trimmed(messages, characterLimit: configuration.contextCharacterLimit)
        return Self.keepingNewestImages(trimmed, limit: configuration.imageLimit)
    }

    /// Не больше `limit` фото на запрос: у старых сообщений фото убираются первыми, текст остаётся.
    nonisolated static func keepingNewestImages(_ messages: [LLMMessage], limit: Int) -> [LLMMessage] {
        var remaining = max(limit, 0)
        return messages.reversed().map { message in
            guard !message.images.isEmpty else { return message }
            let kept = Array(message.images.suffix(remaining))
            remaining -= kept.count
            return LLMMessage(role: message.role, content: message.content, images: kept)
        }.reversed()
    }

    /// Последние сообщения, суммарно не длиннее `characterLimit`. Последнее
    /// (вопрос пользователя) остаётся всегда, даже если само длиннее лимита.
    nonisolated static func trimmed(_ messages: [LLMMessage], characterLimit: Int) -> [LLMMessage] {
        var total = 0
        var kept: [LLMMessage] = []
        for message in messages.reversed() {
            total += message.content.count
            guard kept.isEmpty || total <= characterLimit else { break }
            kept.append(message)
        }
        return kept.reversed()
    }

    // MARK: Вспомогательное

    private func draft(chatId: UUID) -> StreamingDraft? {
        generations[chatId].map { StreamingDraft(messageId: $0.messageId, text: $0.text) }
    }

    private func publishDraft(chatId: UUID) {
        let draft = draft(chatId: chatId)
        for continuation in draftObservers[chatId, default: [:]].values { continuation.yield(draft) }
    }

    private func chatExists(_ chatId: UUID) async throws -> Bool {
        var chats = repository.observeChats().makeAsyncIterator()
        return await chats.next()?.contains { $0.id == chatId } ?? false
    }

    private func retryDate(after duration: Duration) -> Date {
        let (seconds, attoseconds) = duration.components
        return now().addingTimeInterval(Double(seconds) + Double(attoseconds) / 1e18)
    }
}
