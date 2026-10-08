import Foundation
import Observation

/// Диктовка в поле ввода: речь → текст, который пользователь правит и отправляет сам.
/// Владелец — `ChatViewModel`: он отдаёт текст до начала диктовки и получает склейку
/// «старый текст + расшифровка» на каждом обновлении.
@MainActor
@Observable
final class DictationViewModel {
    enum State: Equatable {
        case idle
        /// Разрешения, подготовка микрофона.
        case preparing
        /// Однократная загрузка модели языка (iOS 26), 0…1.
        case downloading(Double)
        case recording
        case unavailable(DictationUnavailability)
        /// Что-то пошло не так — можно попробовать ещё раз.
        case failed
        /// Кнопку отпустили раньше, чем началась запись: подсказываем «зажми и говори».
        case holdHint
    }

    private(set) var state = State.idle
    /// Громкость 0…1 для индикатора записи.
    private(set) var level: Float = 0

    @ObservationIgnored private let transcriber: any SpeechTranscribing
    @ObservationIgnored private let speech: (any SpeechSynthesizing)?
    @ObservationIgnored private let openSettingsAction: () -> Void
    @ObservationIgnored private var session: Task<Void, Never>?
    /// Куда отдавать текст; `nil` — пользователь начал править поле, расшифровку больше не применяем.
    @ObservationIgnored private var onText: ((String) -> Void)?
    /// Сколько ждём дорасшифровку после «Done», прежде чем оборвать сессию.
    @ObservationIgnored private let finishTimeout: Duration

    init(
        transcriber: any SpeechTranscribing,
        speech: (any SpeechSynthesizing)? = nil,
        openSettings: @escaping () -> Void = {},
        finishTimeout: Duration = .seconds(3)
    ) {
        self.transcriber = transcriber
        self.speech = speech
        self.openSettingsAction = openSettings
        self.finishTimeout = finishTimeout
    }

    /// Идёт сессия: подготовка, загрузка модели или запись.
    var isActive: Bool {
        switch state {
        case .preparing, .downloading, .recording: true
        case .idle, .unavailable, .failed, .holdHint: false
        }
    }

    /// Нет разрешения — в сообщении есть кнопка «Open Settings».
    var canOpenSettings: Bool {
        state == .unavailable(.microphoneDenied) || state == .unavailable(.recognitionDenied)
    }

    /// Начинает диктовку. Текст поля = `prefix` + расшифровка (через пробел).
    func start(prefix: String, onText: @escaping (String) -> Void) {
        guard !isActive else { return }
        // Озвучка и микрофон одновременно — эхо и спор за аудиосессию.
        speech?.stop()
        state = .preparing
        level = 0
        self.onText = onText
        let stream = transcriber.dictate()
        session = Task { [weak self] in
            do {
                for try await event in stream {
                    self?.handle(event, prefix: prefix)
                }
                self?.end(.idle)
            } catch let reason as DictationUnavailability {
                self?.end(.unavailable(reason))
            } catch {
                self?.end(Task.isCancelled ? .idle : .failed)
            }
        }
    }

    /// «Done»: выключает микрофон и ждёт последнюю фразу (не дольше `finishTimeout`).
    func finish() async {
        guard isActive, let session else { return }
        guard state == .recording else {
            cancel()
            return
        }
        transcriber.finish()
        let watchdog = Task { [finishTimeout] in
            try? await Task.sleep(for: finishTimeout)
            guard !Task.isCancelled else { return }
            session.cancel()
        }
        await session.value
        watchdog.cancel()
    }

    /// Кнопку отпустили: идёт запись — дописываем последнюю фразу; запись ещё не началась
    /// (разрешения, загрузка модели) — отменяем и подсказываем, что кнопку надо держать.
    func release() async {
        if state == .recording {
            await finish()
        } else if isActive {
            cancel()
            state = .holdHint
        }
    }

    /// Пользователь сам правит поле: его правка важнее — расшифровку дальше не применяем.
    func detach() {
        onText = nil
        guard isActive else { return }
        if state == .recording {
            transcriber.finish()
        } else {
            cancel()
        }
    }

    /// Обрывает сессию: уже вставленный текст остаётся в поле.
    func cancel() {
        onText = nil
        session?.cancel()
        session = nil
        if isActive { state = .idle }
    }

    func dismissMessage() {
        if !isActive { state = .idle }
    }

    func openSettings() {
        dismissMessage()
        openSettingsAction()
    }

    private func handle(_ event: DictationEvent, prefix: String) {
        switch event {
        case let .downloading(fraction):
            state = .downloading(fraction)
        case .recording:
            state = .recording
        case let .level(level):
            self.level = level
        case let .transcript(transcript):
            if state != .recording { state = .recording }
            onText?(Transcript.join(prefix, transcript.text))
        }
    }

    private func end(_ state: State) {
        self.state = state
        level = 0
        onText = nil
        session = nil
    }
}

/// Текст и иконка сообщения под полем ввода, когда диктовка невозможна.
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
            title = "Couldn't start dictation. Please try again."
            systemImage = "exclamationmark.triangle"
        case .holdHint:
            title = "Hold the microphone button while you speak."
            systemImage = "hand.tap"
        case .idle, .preparing, .downloading, .recording:
            return nil
        }
    }
}
