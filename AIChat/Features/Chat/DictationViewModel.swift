import Foundation
import Observation

/// Диктовка «зажми и говори» в два шага: пока кнопка зажата — запись звука, отпустил —
/// запись распознаётся и текст отдаётся владельцу (`ChatViewModel` дописывает его в поле).
@MainActor
@Observable
final class DictationViewModel {
    enum State: Equatable {
        case idle
        /// Разрешения: микрофон, распознавание.
        case preparing
        case recording
        /// Запись остановлена, идёт распознавание.
        case transcribing
        /// Однократная загрузка модели языка (iOS 26) перед распознаванием, 0…1.
        case downloading(Double)
        case unavailable(DictationUnavailability)
        /// Что-то пошло не так — можно попробовать ещё раз.
        case failed
        /// Кнопку отпустили слишком быстро: подсказываем «зажми и говори».
        case holdHint
        /// Записали, но речи не распознали.
        case nothingHeard
    }

    /// Короче — считаем случайным касанием, а не диктовкой.
    static let minimumDuration: Duration = .milliseconds(500)

    private(set) var state = State.idle
    /// Сколько уже записано — «Recording 0:03».
    private(set) var duration: Duration = .zero
    /// Громкость 0…1 для индикатора записи.
    private(set) var level: Float = 0

    @ObservationIgnored private let recorder: any VoiceRecording
    @ObservationIgnored private let transcriber: any SpeechTranscribing
    @ObservationIgnored private let speech: (any SpeechSynthesizing)?
    @ObservationIgnored private let openSettingsAction: () -> Void
    @ObservationIgnored private var onText: ((String) -> Void)?
    /// Палец всё ещё на кнопке (для отпускания во время запроса разрешений).
    @ObservationIgnored private var isHeld = false
    /// Подготовка и запись (до отпускания).
    @ObservationIgnored private var recording: Task<Void, Never>?
    /// Распознавание после отпускания.
    @ObservationIgnored private var transcription: Task<Void, Never>?

    init(
        recorder: any VoiceRecording,
        transcriber: any SpeechTranscribing,
        speech: (any SpeechSynthesizing)? = nil,
        openSettings: @escaping () -> Void = {}
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.speech = speech
        self.openSettingsAction = openSettings
    }

    /// Идёт сессия: подготовка, запись или распознавание.
    var isActive: Bool {
        switch state {
        case .preparing, .recording, .transcribing, .downloading: true
        case .idle, .unavailable, .failed, .holdHint, .nothingHeard: false
        }
    }

    /// Нет разрешения — в сообщении есть кнопка «Open Settings».
    var canOpenSettings: Bool {
        state == .unavailable(.microphoneDenied) || state == .unavailable(.recognitionDenied)
    }

    /// Палец лёг на кнопку: разрешения, затем запись.
    /// - Parameter onText: распознанный текст (непустой) — вызывается один раз в конце.
    func press(onText: @escaping (String) -> Void) {
        guard !isActive else { return }
        // Озвучка и микрофон одновременно — эхо и спор за аудиосессию.
        speech?.stop()
        isHeld = true
        state = .preparing
        duration = .zero
        level = 0
        self.onText = onText
        recording = Task { [weak self] in await self?.record() }
    }

    /// Палец поднялся: распознаём записанное. Возвращается, когда текст уже отдан.
    func release() async {
        isHeld = false
        switch state {
        case .recording:
            if duration < Self.minimumDuration {
                recorder.cancel()
                end(.holdHint)
            } else {
                transcribeRecording()
            }
        case .preparing:
            // Отпустили, пока спрашивали разрешения: записи не было.
            recording?.cancel()
            end(.holdHint)
        default:
            break
        }
        await transcription?.value
    }

    /// VoiceOver: двойное касание начинает и заканчивает запись (держать неудобно).
    func toggle(onText: @escaping (String) -> Void) async {
        if state == .recording || state == .preparing {
            await release()
        } else if !isActive {
            press(onText: onText)
        }
    }

    /// Обрывает всё: запись удаляется, распознавание отменяется, текст не вставляется.
    func cancel() {
        isHeld = false
        recording?.cancel()
        transcription?.cancel()
        if state == .recording { recorder.cancel() }
        if isActive { end(.idle) }
    }

    func dismissMessage() {
        if !isActive { state = .idle }
    }

    func openSettings() {
        dismissMessage()
        openSettingsAction()
    }

    // MARK: Шаги

    private func record() async {
        guard await recorder.requestPermission() else { return end(.unavailable(.microphoneDenied)) }
        do {
            try await transcriber.prepare()
        } catch {
            return end(Self.state(for: error))
        }
        // Пока шли системные запросы разрешений, кнопку отпустили или экран закрыли.
        guard !Task.isCancelled, state == .preparing else { return }
        guard isHeld else { return end(.holdHint) }

        let events: AsyncStream<RecordingEvent>
        do {
            events = try recorder.start()
        } catch {
            return end(.failed)
        }
        state = .recording
        for await event in events {
            guard state == .recording else { break }
            switch event {
            case let .progress(duration, level):
                self.duration = duration
                self.level = level
            case .stoppedAutomatically:
                transcribeRecording()
            }
        }
    }

    /// Останавливает запись и распознаёт её. Синхронно меняет состояние, чтобы отпускание
    /// и автоостановка не запустили распознавание дважды.
    private func transcribeRecording() {
        guard state == .recording else { return }
        level = 0
        guard let url = recorder.stop() else { return end(.failed) }
        state = .transcribing
        transcription = Task { [weak self] in
            await self?.transcribe(url)
        }
    }

    private func transcribe(_ url: URL) async {
        defer { recorder.discard(url) }
        do {
            let text = try await transcriber.transcribe(fileAt: url) { [weak self] fraction in
                Task { @MainActor in self?.downloading(fraction) }
            }
            guard !Task.isCancelled else { return end(.idle) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                end(.nothingHeard)
            } else {
                onText?(trimmed)
                end(.idle)
            }
        } catch {
            end(Task.isCancelled ? .idle : Self.state(for: error))
        }
    }

    private func downloading(_ fraction: Double) {
        guard state == .transcribing || state.isDownloading else { return }
        // Модель скачана — дальше обычное распознавание.
        state = fraction < 1 ? .downloading(fraction) : .transcribing
    }

    private func end(_ state: State) {
        self.state = state
        level = 0
        onText = nil
        recording = nil
        transcription = nil
    }

    private static func state(for error: Error) -> State {
        if let reason = error as? DictationUnavailability { return .unavailable(reason) }
        if error is CancellationError { return .idle }
        return .failed
    }
}

private extension DictationViewModel.State {
    var isDownloading: Bool {
        if case .downloading = self { true } else { false }
    }
}

/// Склейка надиктованного с уже набранным: через один пробел, если его нет на стыке.
enum DictationText {
    static func join(_ head: String, _ tail: String) -> String {
        guard let last = head.last, let first = tail.first else { return head + tail }
        return last.isWhitespace || first.isWhitespace ? head + tail : head + " " + tail
    }
}

/// Текст и иконка сообщения под полем ввода, когда диктовка не получилась.
struct DictationMessagePresentation: Sendable {
    let title: LocalizedStringResource
    let systemImage: String

    init?(state: DictationViewModel.State) {
        switch state {
        case .unavailable(.microphoneDenied):
            title = "Microphone access is off. Allow it in Settings to dictate."
            systemImage = "mic.slash"
        case .unavailable(.recognitionDenied):
            title = "Speech recognition is off. Allow it in Settings to dictate."
            systemImage = "mic.slash"
        case .unavailable(.languageNotSupported):
            title = "Dictation isn't available offline for your language."
            systemImage = "globe"
        case .unavailable(.dictationDisabled):
            // «Open Settings» тут не поможет: он открывает настройки приложения, а не клавиатуры.
            title = "Dictation is turned off on this iPhone. Turn it on in Settings › General › Keyboard."
            systemImage = "keyboard"
        case .unavailable(.serviceUnavailable):
            title = "Speech recognition isn't available right now. Please try again later."
            systemImage = "waveform.slash"
        case .unavailable(.needsDownload):
            title = "Dictation needs a one-time download. Connect to the internet and try again."
            systemImage = "arrow.down.circle"
        case .failed:
            title = "Couldn't recognize the recording. Please try again."
            systemImage = "exclamationmark.triangle"
        case .holdHint:
            title = "Hold the microphone button while you speak."
            systemImage = "hand.tap"
        case .nothingHeard:
            title = "Didn't catch that. Try again."
            systemImage = "ear"
        case .idle, .preparing, .recording, .transcribing, .downloading:
            return nil
        }
    }
}
