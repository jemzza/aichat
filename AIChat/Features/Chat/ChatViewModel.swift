import Foundation
import Observation

/// Экран чата: лента сообщений и поле ввода. Сообщения — только из базы
/// (`observeMessages`); поверх ответа в статусе `streaming` накладывается живой
/// черновик из `ChatSession`. Отправка и «Stop» идут через `ChatSession`.
@MainActor
@Observable
final class ChatViewModel {
    /// `nil` — новый чат: в базе его ещё нет. После первой отправки получает id,
    /// экран при этом не пересоздаётся (подписки перезапускаются по `chatId`).
    private(set) var chatId: UUID?
    private(set) var messages: [Message] = []
    private(set) var draft: StreamingDraft?
    /// Пока не пришло первое значение из базы, пустое состояние не показываем.
    private(set) var hasLoaded: Bool
    /// Пользователь у нижнего края ленты: новые токены прокручивают её вниз.
    /// Меняется только от действий пользователя, а не от роста контента.
    private(set) var isPinnedToBottom = true

    /// Текст в поле ввода.
    var inputText = ""
    /// Сообщение уходит в базу — защита от двойного нажатия.
    private(set) var isSending = false
    private(set) var sendFailed = false
    private(set) var retryFailed = false
    /// Только что скопированный ответ — на иконке на секунду появляется галочка.
    private(set) var copiedMessageId: UUID?

    @ObservationIgnored private let repository: any ChatRepository
    @ObservationIgnored private let session: any ChatSession
    @ObservationIgnored private let onChatCreated: (UUID) -> Void
    @ObservationIgnored private let copyToClipboard: (String) -> Void
    @ObservationIgnored private var copiedResetTask: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar

    /// - Parameter copyToClipboard: запись в буфер обмена (`UIPasteboard` из композиции),
    ///   чтобы ViewModel не зависела от UIKit.
    init(
        chatId: UUID?,
        repository: any ChatRepository,
        session: any ChatSession,
        onChatCreated: @escaping (UUID) -> Void = { _ in },
        copyToClipboard: @escaping (String) -> Void = { _ in },
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.chatId = chatId
        self.repository = repository
        self.session = session
        self.onChatCreated = onChatCreated
        self.copyToClipboard = copyToClipboard
        self.now = now
        self.calendar = calendar
        hasLoaded = chatId == nil
    }

    /// Сообщения для показа: у стримящегося ответа текст — из черновика.
    var displayedMessages: [Message] {
        guard let draft else { return messages }
        return messages.map { message in
            guard message.id == draft.messageId, message.status == .streaming else { return message }
            var message = message
            message.text = draft.text
            return message
        }
    }

    var showsScrollToBottomButton: Bool { !isPinnedToBottom && !messages.isEmpty }

    // MARK: Пустой экран

    /// Новый чат без сообщений: приветствие и подсказки.
    var showsEmptyState: Bool { hasLoaded && messages.isEmpty && !isSending }

    /// Время суток берётся при отрисовке — после ночи на экране уже «Good morning».
    var greeting: Greeting { Greeting(date: now(), calendar: calendar) }

    var suggestions: [Suggestion] { Suggestion.all }

    /// Чип отправляет запрос сразу, не трогая то, что пользователь начал печатать.
    func send(suggestion: Suggestion) async {
        await send(text: String(localized: suggestion.prompt))
    }

    // MARK: Поле ввода

    /// Идёт генерация ответа — вместо «Send» показываем «Stop».
    var isGenerating: Bool {
        messages.contains { $0.role == .assistant && $0.status == .streaming }
    }

    var canSend: Bool {
        !isSending && !isGenerating && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() async {
        guard canSend else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""
        await send(text: text, restoresInput: true)
    }

    private func send(text: String, restoresInput: Bool = false) async {
        guard !isSending, !isGenerating, !text.isEmpty else { return }
        isSending = true
        isPinnedToBottom = true
        defer { isSending = false }
        do {
            let id = try await session.send(text, inChat: chatId)
            if chatId == nil {
                chatId = id
                // Подписка на новый чат ещё не вернула сообщения — не мигаем пустым экраном.
                hasLoaded = false
                onChatCreated(id)
            }
        } catch {
            // Ничего не потеряли: возвращаем текст в поле, если пользователь не начал новый.
            if restoresInput, inputText.isEmpty { inputText = text }
            sendFailed = true
        }
    }

    func stop() {
        guard let chatId, isGenerating else { return }
        session.stopGenerating(chatId: chatId)
    }

    func dismissSendFailure() {
        sendFailed = false
    }

    // MARK: Действия с ответом

    /// «Retry» доступен у ответа `failed`/`interrupted`/`cancelled`, пока в чате ничего не генерируется.
    /// Ожидание `retry-after` при 429 проверяет View (обратный отсчёт).
    func canRetry(_ message: Message) -> Bool {
        message.role == .assistant && message.status.isRetryable && !isGenerating
    }

    func retry(_ message: Message) async {
        guard let chatId, canRetry(message) else { return }
        isPinnedToBottom = true
        do {
            try await session.retry(assistantMessageId: message.id, inChat: chatId)
        } catch {
            retryFailed = true
        }
    }

    func dismissRetryFailure() {
        retryFailed = false
    }

    /// Копирование произвольного фрагмента ответа (блок кода).
    func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        copyToClipboard(text)
    }

    func copy(_ message: Message) {
        guard !message.text.isEmpty else { return }
        copyToClipboard(message.text)
        copiedMessageId = message.id
        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copiedMessageId = nil
        }
    }

    // MARK: Подписки (живут, пока жива задача вызывающего — `.task(id: chatId)` во View)

    func observeMessages() async {
        guard let chatId else { return }
        for await messages in repository.observeMessages(chatId: chatId) {
            self.messages = messages
            hasLoaded = true
        }
    }

    func observeDraft() async {
        guard let chatId else { return }
        for await draft in session.draftUpdates(chatId: chatId) {
            self.draft = draft
        }
    }

    // MARK: Прокрутка

    /// Пользователь прокрутил ленту: у нижнего края — снова следим за новыми токенами.
    func userScrolled(isAtBottom: Bool) {
        isPinnedToBottom = isAtBottom
    }

    func scrollToBottomTapped() {
        isPinnedToBottom = true
    }
}
