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

    @ObservationIgnored private let repository: any ChatRepository
    @ObservationIgnored private let session: any ChatSession
    @ObservationIgnored private let onChatCreated: (UUID) -> Void

    init(
        chatId: UUID?,
        repository: any ChatRepository,
        session: any ChatSession,
        onChatCreated: @escaping (UUID) -> Void = { _ in }
    ) {
        self.chatId = chatId
        self.repository = repository
        self.session = session
        self.onChatCreated = onChatCreated
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
        isSending = true
        isPinnedToBottom = true
        defer { isSending = false }
        do {
            let id = try await session.send(text, inChat: chatId)
            if chatId == nil {
                chatId = id
                onChatCreated(id)
            }
        } catch {
            // Ничего не потеряли: возвращаем текст в поле, если пользователь не начал новый.
            if inputText.isEmpty { inputText = text }
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
