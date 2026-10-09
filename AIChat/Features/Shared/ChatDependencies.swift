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
    /// Фото из библиотеки → уменьшенный JPEG для вложения; `nil` — это не картинка.
    let prepareImage: @Sendable (Data) async -> Data?
    /// Подпись под названием чата («Groq · <model>»).
    let modelName: LocalizedStringResource
    /// Настройки (экран Settings).
    let settings: any SettingsStoring
    /// Статус разрешений диктовки (экран Privacy).
    let permissions: any PermissionStatusProviding
    /// Открывает страницу приложения в системных Настройках.
    let openAppSettings: @MainActor () -> Void
}
