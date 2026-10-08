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
    /// Фото из библиотеки → уменьшенный JPEG для вложения; `nil` — это не картинка.
    let prepareImage: @Sendable (Data) async -> Data?
    /// Подпись под названием чата («Groq · <model>»).
    let modelName: LocalizedStringResource
}
