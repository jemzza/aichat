import Foundation

/// Слать ли уведомление: переключатель включён, приложение не активно, разрешение есть.
/// На переднем плане не уведомляем ни о чём (решение заказчика, docs/task.md).
enum NotificationPolicy {
    static func shouldNotify(isEnabled: Bool, isAppActive: Bool, authorization: NotificationAuthorization) -> Bool {
        isEnabled && !isAppActive && authorization == .authorized
    }
}

/// Локальные уведомления о событиях `ChatService`: готовый ответ и отправленный outbox.
@MainActor
final class NotificationService: ChatEventHandling {
    /// Сколько символов ответа идёт в текст уведомления.
    nonisolated static let previewLength = 160

    private let settings: any SettingsStoring
    private let scheduler: any LocalNotificationScheduling
    private let activity: any AppActivityProviding
    private let repository: any ChatRepository
    /// Markdown ответа → простой текст (заголовки, списки, код).
    private let plainText: @Sendable (String) -> String

    init(
        settings: any SettingsStoring,
        scheduler: any LocalNotificationScheduling,
        activity: any AppActivityProviding,
        repository: any ChatRepository,
        plainText: @escaping @Sendable (String) -> String = { $0 }
    ) {
        self.settings = settings
        self.scheduler = scheduler
        self.activity = activity
        self.repository = repository
        self.plainText = plainText
    }

    func replyDidFinish(chatId: UUID, text: String) async {
        guard await shouldNotify(isEnabled: settings.notifyOnReply) else { return }
        var chats = repository.observeChats().makeAsyncIterator()
        let title = await chats.next()?.first { $0.id == chatId }?.title
        // Чат удалили, пока дописывался ответ, — открывать нечего.
        guard let title else { return }
        await scheduler.schedule(LocalNotification(title: title, body: Self.preview(plainText(text)), chatId: chatId))
    }

    func queuedMessagesDidSend(count: Int) async {
        guard count > 0, await shouldNotify(isEnabled: settings.notifyOnQueuedSent) else { return }
        await scheduler.schedule(LocalNotification(
            title: String(localized: "Queued messages sent"),
            body: String(localized: "\(count) messages waiting for a connection were sent."),
            chatId: nil
        ))
    }

    /// Начало ответа одной строкой, не длиннее `previewLength`.
    nonisolated static func preview(_ text: String) -> String {
        let singleLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard singleLine.count > previewLength else { return singleLine }
        return String(singleLine.prefix(previewLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func shouldNotify(isEnabled: Bool) async -> Bool {
        // Дешёвые проверки — до запроса статуса разрешения у системы.
        guard isEnabled, !activity.isAppActive else { return false }
        return NotificationPolicy.shouldNotify(isEnabled: isEnabled, isAppActive: activity.isAppActive,
                                               authorization: await scheduler.authorization())
    }
}
