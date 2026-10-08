import Foundation

/// Расшифровка диктовки с начала сессии.
struct Transcript: Hashable, Sendable {
    /// Уже не изменится.
    var finalized = ""
    /// Текущая гипотеза распознавателя — ещё может поменяться.
    var volatile = ""

    var text: String { Self.join(finalized, volatile) }

    /// Склейка двух кусков текста через один пробел (если его ещё нет на стыке).
    static func join(_ head: String, _ tail: String) -> String {
        guard let last = head.last, let first = tail.first else { return head + tail }
        return last.isWhitespace || first.isWhitespace ? head + tail : head + " " + tail
    }
}

/// Почему диктовка невозможна — у каждой причины свой текст в UI.
enum DictationUnavailability: Error, Hashable, Sendable {
    case microphoneDenied
    /// Только путь iOS 18 (`SFSpeechRecognizer`).
    case recognitionDenied
    /// Ни один из языков пользователя не распознаётся на устройстве.
    case languageNotSupported
    /// iOS 26: модели языка ещё нет, а скачать её сейчас нельзя (нет сети).
    case needsDownload
    /// Офлайн-модели нет, сеть есть, но сервер распознавания Apple сейчас недоступен.
    case serviceUnavailable
    /// В системе выключена диктовка («Siri и Диктовка») — без неё `SFSpeechRecognizer` не работает.
    case dictationDisabled
}

enum DictationEvent: Hashable, Sendable {
    /// Однократная загрузка модели языка (iOS 26), 0…1.
    case downloading(fraction: Double)
    /// Микрофон включён, можно говорить.
    case recording
    /// Громкость входа 0…1 — для индикатора.
    case level(Float)
    case transcript(Transcript)
}

/// Диктовка: речь → текст, полностью на устройстве. Аудио никуда не сохраняется.
/// Реализации: `AnalyzerSpeechTranscriber` (iOS 26), `RecognizerSpeechTranscriber` (iOS 18),
/// `FakeSpeechTranscriber` (DEBUG).
@MainActor
protocol SpeechTranscribing: AnyObject {
    /// Сессия диктовки: спрашивает разрешения, при необходимости скачивает модель,
    /// включает микрофон. Ошибка — `DictationUnavailability` или любая другая («не вышло»).
    /// Поток заканчивается после `finish()` (с последней фразой) или ошибки;
    /// прекращение итерации отменяет запись.
    func dictate() -> AsyncThrowingStream<DictationEvent, Error>

    /// «Готово»: выключает микрофон, дорасшифровывает сказанное и завершает поток.
    func finish()
}
