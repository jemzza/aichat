import Foundation
import Observation

/// Лента сообщений одного чата. Сообщения — только из базы (`observeMessages`);
/// поверх ответа в статусе `streaming` накладывается живой черновик из `ChatSession`.
@MainActor
@Observable
final class ChatViewModel {
    /// `nil` — новый чат: в базе его ещё нет, лента пустая.
    let chatId: UUID?
    private(set) var messages: [Message] = []
    private(set) var draft: StreamingDraft?
    /// Пока не пришло первое значение из базы, пустое состояние не показываем.
    private(set) var hasLoaded: Bool
    /// Пользователь у нижнего края ленты: новые токены прокручивают её вниз.
    /// Меняется только от действий пользователя, а не от роста контента.
    private(set) var isPinnedToBottom = true

    @ObservationIgnored private let repository: any ChatRepository
    @ObservationIgnored private let session: any ChatSession

    init(chatId: UUID?, repository: any ChatRepository, session: any ChatSession) {
        self.chatId = chatId
        self.repository = repository
        self.session = session
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

    // MARK: Подписки (живут, пока жива задача вызывающего — `.task` во View)

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
