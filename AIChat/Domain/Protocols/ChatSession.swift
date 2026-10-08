import Foundation

/// Живой текст ответа, который сейчас стримится. Существует только в памяти
/// (исключение из offline-first): ViewModel накладывает его поверх сообщения
/// со статусом `streaming`, пока в базе лежит более старая версия текста.
struct StreamingDraft: Hashable, Sendable {
    let messageId: UUID
    let text: String
}

/// То, что экранам нужно от `ChatService` сверх чтения из `ChatRepository`.
/// Реализации: `ChatService` (приложение) и `PreviewChatSession` (превью).
@MainActor
protocol ChatSession: AnyObject {
    /// Черновик стримящегося ответа в чате: текущее значение сразу, дальше — при каждом токене.
    /// `nil` — в этом чате сейчас ничего не стримится.
    func draftUpdates(chatId: UUID) -> AsyncStream<StreamingDraft?>

    /// Отправляет сообщение пользователя. Есть сеть — сообщение `sent` и ответ `streaming`
    /// (генерацией владеет сервис); нет — сообщение `pending`.
    /// - Parameter images: фото во вложении (уже уменьшенные), не больше `ImageAttachment.maxPerMessage`.
    /// - Parameter chatId: `nil` — новый чат: создаётся вместе с первым сообщением.
    /// - Returns: id чата, в который ушло сообщение.
    func send(_ text: String, images: [ImageAttachment], inChat chatId: UUID?) async throws -> UUID

    /// «Stop»: отменяет генерацию в чате; полученный текст сохраняется со статусом `cancelled`.
    func stopGenerating(chatId: UUID)

    /// «Retry»: перезапрашивает ответ `failed`/`interrupted`/`cancelled` в том же сообщении.
    /// Повторное нажатие во время генерации ничего не делает (`ChatRepository.claimRetry`).
    func retry(assistantMessageId: UUID, inChat chatId: UUID) async throws

    /// Можно ли сейчас ответить на `pending` моделью на устройстве: сети нет,
    /// а системная модель доступна (iOS 26). Иначе кнопки «Answer offline» нет.
    var canAnswerOffline: Bool { get }

    /// «Answer offline»: сообщение `pending` → `sent`, ответ генерирует модель на устройстве.
    /// Ничего не делает, если ответить офлайн нельзя или сообщение уже ушло.
    func answerOffline(messageId: UUID, inChat chatId: UUID) async throws

    /// Удаляет чат и отменяет его генерацию, если она идёт.
    func deleteChat(id: UUID) async throws
}

extension ChatSession {
    /// Сообщение без фото.
    func send(_ text: String, inChat chatId: UUID?) async throws -> UUID {
        try await send(text, images: [], inChat: chatId)
    }
}
