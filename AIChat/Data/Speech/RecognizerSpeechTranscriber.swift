import AVFoundation
import Speech

/// Диктовка на `SFSpeechRecognizer` — только on-device (`requiresOnDeviceRecognition`):
/// язык без офлайн-распознавания не используем. Путь iOS 18 и запасной путь iOS 26.
@MainActor
final class RecognizerSpeechTranscriber: SpeechTranscribing {
    private struct Session {
        let id: UUID
        let capture: AudioCapture
        let request: SFSpeechAudioBufferRecognitionRequest
        let task: SFSpeechRecognitionTask
        let continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation
    }

    private var session: Session?
    private var interruptions: Task<Void, Never>?

    func dictate() -> AsyncThrowingStream<DictationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<DictationEvent, Error>.makeStream()
        let id = UUID()
        let setup = Task { [weak self] in
            do {
                try await self?.start(id: id, continuation: continuation)
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { [weak self] _ in
            setup.cancel()
            Task { @MainActor in self?.cancel(id: id) }
        }
        return stream
    }

    func finish() {
        guard let session else { return }
        // Микрофон выключаем сразу; финальный результат придёт в обработчик задачи.
        session.capture.stop()
        session.request.endAudio()
    }

    private func start(id: UUID, continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation) async throws {
        if let session { cancel(id: session.id) }

        guard await Self.requestAuthorization() else { throw DictationUnavailability.recognitionDenied }
        guard await MicrophonePermission.request() else { throw DictationUnavailability.microphoneDenied }
        guard let recognizer = Self.onDeviceRecognizer() else { throw DictationUnavailability.languageNotSupported }
        try Task.checkCancellation()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Обработчик зовётся не с главного потока: достаём значения здесь, дальше — Sendable.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            if let text {
                let transcript = isFinal ? Transcript(finalized: text) : Transcript(volatile: text)
                continuation.yield(.transcript(transcript))
            }
            if isFinal || error != nil {
                // Ошибка после «Готово» (тишина, нечего распознавать) — не ошибка для пользователя.
                Task { @MainActor in self?.end(id: id) }
            }
        }

        // `SFSpeechAudioBufferRecognitionRequest` не `Sendable`, но `append` документирован
        // как безопасный с аудиопотока — ради этого и существует буферный запрос.
        nonisolated(unsafe) let unsafeRequest = request
        let capture = AudioCapture()
        do {
            try capture.start(format: nil) { buffer, level in
                unsafeRequest.append(buffer)
                continuation.yield(.level(level))
            }
        } catch {
            task.cancel()
            throw error
        }
        session = Session(id: id, capture: capture, request: request, task: task, continuation: continuation)
        observeInterruptions()
        continuation.yield(.recording)
    }

    /// Нормальное завершение: финальный результат уже отдан.
    private func end(id: UUID) {
        guard let session, session.id == id else { return }
        session.capture.stop()
        session.continuation.finish()
        self.session = nil
        interruptions?.cancel()
    }

    private func cancel(id: UUID) {
        guard let session, session.id == id else { return }
        session.task.cancel()
        session.capture.stop()
        session.continuation.finish()
        self.session = nil
        interruptions?.cancel()
    }

    /// Звонок, Siri, отключённые наушники — заканчиваем диктовку, сказанное остаётся.
    private func observeInterruptions() {
        interruptions?.cancel()
        interruptions = Task { [weak self] in
            await AudioInterruptions.first()
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private static func onDeviceRecognizer() -> SFSpeechRecognizer? {
        for locale in DictationLocales.candidates {
            if let recognizer = SFSpeechRecognizer(locale: locale),
               recognizer.supportsOnDeviceRecognition, recognizer.isAvailable {
                return recognizer
            }
        }
        return nil
    }

    private static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }
}

/// Первое событие, после которого запись надо остановить: прерывание аудиосессии
/// или потеря устройства ввода (сняли гарнитуру).
enum AudioInterruptions {
    static func first() async {
        let center = NotificationCenter.default
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in center.notifications(named: AVAudioSession.interruptionNotification) { return }
            }
            group.addTask {
                for await notification in center.notifications(named: AVAudioSession.routeChangeNotification) {
                    let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    if raw.flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable { return }
                }
            }
            await group.next()
            group.cancelAll()
        }
    }
}
