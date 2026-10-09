import Foundation

enum RecordingEvent: Hashable, Sendable {
    /// Сколько записано и громкость входа 0…1 — для «Recording 0:03» и индикатора.
    case progress(duration: Duration, level: Float)
    /// Запись остановилась сама: лимит длительности, звонок, Siri, сняли гарнитуру.
    /// Записанное надо распознать.
    case stoppedAutomatically
}

/// Запись голоса для диктовки во временный файл. Файл живёт только до распознавания:
/// после него вызывающий удаляет его через `discard(_:)`.
/// Реализации: `SystemVoiceRecorder` (`AVAudioRecorder`), `FakeVoiceRecorder` (DEBUG).
@MainActor
protocol VoiceRecording: AnyObject {
    /// Разрешение на микрофон (спрашивает, если ещё не спрашивали).
    func requestPermission() async -> Bool

    /// Начинает запись. Поток событий заканчивается, когда запись остановлена.
    func start() throws -> AsyncStream<RecordingEvent>

    /// Останавливает запись и отдаёт файл; `nil` — записи не было.
    func stop() -> URL?

    /// Обрывает запись и удаляет файл.
    func cancel()

    /// Удаляет файл после распознавания.
    func discard(_ url: URL)
}
