import Foundation

/// Всё, из чего собираются экраны. Создаётся в `AppContainer`.
@MainActor
struct ChatDependencies {
    let repository: any ChatRepository
    let session: any ChatSession
    /// Для баннера «No connection».
    let connectivity: any ConnectivityMonitoring
    /// Озвучка ответов («Read aloud»).
    let speech: any SpeechSynthesizing
    /// Диктовка в поле ввода.
    let transcriber: any SpeechTranscribing
    /// Подпись под названием чата («Groq · <model>»).
    let modelName: LocalizedStringResource
}
