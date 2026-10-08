import Foundation

/// Что сейчас озвучивается. Одно состояние на всё приложение: новое чтение прерывает предыдущее.
enum SpeechPlayback: Hashable, Sendable {
    case idle
    case speaking(messageId: UUID)

    var messageId: UUID? {
        if case let .speaking(messageId) = self { messageId } else { nil }
    }
}

/// Озвучка ответов («Read aloud»). Реализации: `SystemSpeechSynthesizer` (приложение)
/// и `FakeSpeechSynthesizer` (превью, тесты). Живёт в `AppContainer`, а не в экране:
/// чтение не обрывается при смене чата, и ViewModel узнаёт о нём только из `playbackUpdates()`.
@MainActor
protocol SpeechSynthesizing: AnyObject {
    /// Текущее состояние сразу, дальше — при каждом изменении (в т.ч. когда чтение закончилось само).
    func playbackUpdates() -> AsyncStream<SpeechPlayback>

    /// Читает уже подготовленный текст (без Markdown); предыдущее чтение прерывается.
    func speak(_ text: String, messageId: UUID)

    func stop()
}
