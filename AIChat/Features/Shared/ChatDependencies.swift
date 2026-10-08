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
    /// Диктовка в поле ввода: запись голоса и её распознавание.
    let recorder: any VoiceRecording
    let transcriber: any SpeechTranscribing
    /// Подпись под названием чата («Groq · <model>»).
    let modelName: LocalizedStringResource
}
