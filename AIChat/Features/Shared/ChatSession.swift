import Foundation

/// Живой текст ответа, который сейчас стримится. Существует только в памяти
/// (исключение из offline-first): ViewModel накладывает его поверх сообщения
/// со статусом `streaming`, пока в базе лежит более старая версия текста.
struct StreamingDraft: Hashable, Sendable {
    let messageId: UUID
    let text: String
}

/// То, что экранам нужно от `ChatService` (шаг 3.2) сверх чтения из `ChatRepository`.
/// `ChatService` реализует этот протокол; превью и `-mockData` — `PreviewChatSession`.
///
/// Объявлен в `Features`, а не в `Domain`: это контракт UI-слоя, а `ChatService`
/// будет писаться параллельно (см. отчёт по шагам 4.1–4.4).
@MainActor
protocol ChatSession: AnyObject {
    /// Черновик стримящегося ответа в чате: текущее значение сразу, дальше — при каждом токене.
    /// `nil` — в этом чате сейчас ничего не стримится.
    func draftUpdates(chatId: UUID) -> AsyncStream<StreamingDraft?>

    /// Отправляет сообщение пользователя. Есть сеть — сообщение `sent` и ответ `streaming`
    /// (генерацией владеет сервис); нет — сообщение `pending`.
    /// - Parameter chatId: `nil` — новый чат: создаётся вместе с первым сообщением.
    /// - Returns: id чата, в который ушло сообщение.
    func send(_ text: String, inChat chatId: UUID?) async throws -> UUID

    /// «Stop»: отменяет генерацию в чате; полученный текст сохраняется со статусом `cancelled`.
    func stopGenerating(chatId: UUID)

    /// «Retry»: перезапрашивает ответ `failed`/`interrupted`/`cancelled` в том же сообщении.
    /// Повторное нажатие во время генерации ничего не делает (`ChatRepository.claimRetry`).
    func retry(assistantMessageId: UUID, inChat chatId: UUID) async throws

    /// Удаляет чат и отменяет его генерацию, если она идёт.
    func deleteChat(id: UUID) async throws
}

/// Всё, из чего собираются экраны. Создаётся в `AppContainer`.
@MainActor
struct ChatDependencies {
    let repository: any ChatRepository
    let session: any ChatSession
    /// Для баннера «No connection».
    let connectivity: any ConnectivityMonitoring
    /// Подпись под названием чата («Groq · <model>»).
    let modelName: LocalizedStringResource
}
