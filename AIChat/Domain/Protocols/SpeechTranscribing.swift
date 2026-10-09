import Foundation

/// Почему диктовка невозможна — у каждой причины свой текст в UI.
enum DictationUnavailability: Error, Hashable, Sendable {
    case microphoneDenied
    /// Путь `SFSpeechRecognizer`.
    case recognitionDenied
    /// Ни один из языков пользователя не распознаётся на устройстве, а сети нет.
    case languageNotSupported
    /// iOS 26: модели языка ещё нет, а скачать её сейчас нельзя (нет сети).
    case needsDownload
    /// Офлайн-модели нет, сеть есть, но сервер распознавания Apple сейчас недоступен.
    case serviceUnavailable
    /// В системе выключена диктовка («Siri и Диктовка») — без неё `SFSpeechRecognizer` не работает.
    case dictationDisabled
}

/// Распознавание записанной речи: файл → текст, по возможности на устройстве.
/// Реализации: `AnalyzerSpeechTranscriber` (iOS 26), `RecognizerSpeechTranscriber` (iOS 18 и
/// запасной путь), `FakeSpeechTranscriber` (DEBUG).
@MainActor
protocol SpeechTranscribing: AnyObject {
    /// Разрешение на распознавание, если выбранному пути оно нужно. Спрашивается до записи,
    /// чтобы системный запрос не появился, когда речь уже сказана.
    func prepare() async throws

    /// Текст записи; пустая строка — речи не было. Ошибка — `DictationUnavailability` или любая
    /// другая («не вышло»).
    /// - Parameter onDownloadProgress: однократная загрузка модели языка (iOS 26), 0…1.
    func transcribe(fileAt url: URL, onDownloadProgress: @escaping @Sendable (Double) -> Void) async throws -> String
}
