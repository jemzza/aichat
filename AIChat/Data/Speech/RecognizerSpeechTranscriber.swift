import AVFoundation
import OSLog
import Speech

/// Диктовка на `SFSpeechRecognizer`: на устройстве, если язык это поддерживает; иначе,
/// если есть сеть, — через серверы Apple. Путь iOS 18 и запасной путь iOS 26.
@MainActor
final class RecognizerSpeechTranscriber: SpeechTranscribing {
    private struct Session {
        let id: UUID
        let capture: AudioCapture
        let request: SFSpeechAudioBufferRecognitionRequest
        let task: SFSpeechRecognitionTask
        let continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation
        /// Пользователь отпустил кнопку: ошибка «нечего распознавать» после этого — не ошибка.
        var isFinishing = false
    }

    private let connectivity: any ConnectivityMonitoring
    private var session: Session?
    private var interruptions: Task<Void, Never>?

    init(connectivity: any ConnectivityMonitoring) {
        self.connectivity = connectivity
    }

    func dictate() -> AsyncThrowingStream<DictationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<DictationEvent, Error>.makeStream()
        let id = UUID()
        let setup = Task { [weak self] in
            do {
                try await self?.start(id: id, continuation: continuation)
            } catch {
                DictationLog.logger.error("Recognizer: \(String(describing: error), privacy: .public)")
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
        self.session?.isFinishing = true
        // Микрофон выключаем сразу; финальный результат придёт в обработчик задачи.
        session.capture.stop()
        session.request.endAudio()
    }

    private func start(id: UUID, continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation) async throws {
        if let session { cancel(id: session.id) }

        guard await Self.requestAuthorization() else { throw DictationUnavailability.recognitionDenied }
        guard await MicrophonePermission.request() else { throw DictationUnavailability.microphoneDenied }
        let (recognizer, onDevice) = try Self.recognizer(isOnline: connectivity.isOnline)
        try Task.checkCancellation()
        DictationLog.logger.info(
            "Recognizer: \(recognizer.locale.identifier, privacy: .public), onDevice=\(onDevice, privacy: .public)"
        )

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        let task = Self.recognitionTask(recognizer: recognizer, request: request, continuation: continuation) {
            [weak self] failure in
            Task { @MainActor in self?.end(id: id, failure: failure) }
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

    /// Распознавание закончилось: финальный результат уже отдан или пришла ошибка.
    /// Ошибка до отпускания кнопки — для пользователя («диктовка выключена», «не вышло»);
    /// после — обычно «речи не было», текст уже в поле.
    private func end(id: UUID, failure: RecognitionFailure?) {
        guard let session, session.id == id else { return }
        session.capture.stop()
        switch failure {
        case .dictationDisabled:
            session.continuation.finish(throwing: DictationUnavailability.dictationDisabled)
        case .other(let error) where !session.isFinishing:
            session.continuation.finish(throwing: error)
        case .other, nil:
            session.continuation.finish()
        }
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

    /// Распознаватель для первого подходящего языка пользователя: сначала на устройстве,
    /// затем (если есть сеть) — серверный.
    private static func recognizer(isOnline: Bool) throws -> (SFSpeechRecognizer, onDevice: Bool) {
        let recognizers = DictationLocales.candidates.compactMap { SFSpeechRecognizer(locale: $0) }
        let summary = recognizers.map {
            "\($0.locale.identifier) onDevice=\($0.supportsOnDeviceRecognition) available=\($0.isAvailable)"
        }
        DictationLog.logger.info(
            "Recognizers: \(summary.joined(separator: "; "), privacy: .public), online=\(isOnline, privacy: .public)"
        )
        if let local = recognizers.first(where: { $0.supportsOnDeviceRecognition }) {
            return (local, true)
        }
        guard isOnline else { throw DictationUnavailability.languageNotSupported }
        guard let remote = recognizers.first(where: \.isAvailable) else {
            throw DictationUnavailability.serviceUnavailable
        }
        return (remote, false)
    }

    // MARK: Колбэки Speech — `nonisolated`

    // Колбэки ниже система вызывает на своих очередях. Созданные внутри `@MainActor`-метода,
    // они унаследовали бы изоляцию главного актора, и Swift 6 остановил бы приложение
    // проверкой исполнителя. Поэтому они создаются в `nonisolated`-функциях и трогают
    // только `Sendable`-значения.

    private nonisolated static func recognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation,
        onEnd: @escaping @Sendable (RecognitionFailure?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            if let text {
                let transcript = isFinal ? Transcript(finalized: text) : Transcript(volatile: text)
                continuation.yield(.transcript(transcript))
            }
            if let error {
                DictationLog.logger.info("Recognition ended: \(String(describing: error), privacy: .public)")
                onEnd(RecognitionFailure(error))
            } else if isFinal {
                onEnd(nil)
            }
        }
    }

    private nonisolated static func requestAuthorization() async -> Bool {
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

/// Ошибка распознавания, сведённая к тому, что важно для UI (`Sendable`, в отличие от `NSError`).
enum RecognitionFailure: Sendable {
    /// В системе выключены «Siri и Диктовка» — `SFSpeechRecognizer` без этого не работает.
    case dictationDisabled
    case other(any Error & Sendable)

    init(_ error: any Error) {
        let error = error as NSError
        if error.domain == "kLSRErrorDomain", error.code == 201 {
            self = .dictationDisabled
        } else {
            self = .other(RecognitionError(domain: error.domain, code: error.code))
        }
    }
}

/// Код ошибки распознавания без `userInfo` — его достаточно для лога и `failed`.
struct RecognitionError: Error, Sendable {
    let domain: String
    let code: Int
}

/// Журнал диктовки: какой путь выбран и почему не вышло. Текст речи сюда не пишем.
enum DictationLog {
    static let logger = Logger(subsystem: "com.example.aichat.app", category: "Dictation")
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
