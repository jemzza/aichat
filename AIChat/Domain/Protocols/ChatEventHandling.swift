import Foundation

/// События `ChatService`, на которые реагируют уведомления. Протокол — чтобы сервис
/// не зависел от UserNotifications. Методы `async`: сервис ждёт обработку, пока у него
/// ещё есть фоновое время (`beginBackgroundTask`).
@MainActor
protocol ChatEventHandling: AnyObject {
    /// Ответ дописан до конца (`done`, непустой текст).
    func replyDidFinish(chatId: UUID, text: String) async
    /// Outbox отправил сообщения, ждавшие сети; `count > 0`, один раз за проход.
    func queuedMessagesDidSend(count: Int) async
}
