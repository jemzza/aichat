import AVFoundation
import Speech

/// Диктовка на `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26), на устройстве.
/// Модель языка система скачивает один раз — при первой диктовке, если есть сеть.
/// Без модели и без сети (или если язык не поддерживается) — запасной путь
/// `RecognizerSpeechTranscriber` (on-device `SFSpeechRecognizer`).
@available(iOS 26, *)
@MainActor
final class AnalyzerSpeechTranscriber: SpeechTranscribing {
    private struct Session {
        let id: UUID
        let capture: AudioCapture
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
    }

    private let connectivity: any ConnectivityMonitoring
    private let fallback: RecognizerSpeechTranscriber
    private var session: Session?
    /// Сессия идёт через запасной путь — `finish()` уходит туда.
    private var usesFallback = false
    private var interruptions: Task<Void, Never>?

    init(connectivity: any ConnectivityMonitoring) {
        self.connectivity = connectivity
        fallback = RecognizerSpeechTranscriber(connectivity: connectivity)
    }

    func dictate() -> AsyncThrowingStream<DictationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<DictationEvent, Error>.makeStream()
        let id = UUID()
        let run = Task { [weak self] in
            do {
                try await self?.run(id: id, continuation: continuation)
                continuation.finish()
            } catch {
                DictationLog.logger.error("Analyzer: \(String(describing: error), privacy: .public)")
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { [weak self] _ in
            run.cancel()
            Task { @MainActor in await self?.cancel(id: id) }
        }
        return stream
    }

    func finish() {
        if usesFallback {
            fallback.finish()
            return
        }
        guard let session else { return }
        // Микрофон выключаем сразу; анализатор дорасшифровывает уже полученное аудио.
        session.capture.stop()
        session.input.finish()
        Task { try? await session.analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    // MARK: Сессия

    private func run(id: UUID, continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation) async throws {
        if let session { await cancel(id: session.id) }
        usesFallback = false

        guard let transcriber = try await readyTranscriber(continuation: continuation) else {
            DictationLog.logger.info("Analyzer: no ready model, using SFSpeechRecognizer")
            usesFallback = true
            defer { usesFallback = false }
            for try await event in fallback.dictate() { continuation.yield(event) }
            return
        }
        guard await MicrophonePermission.request() else { throw DictationUnavailability.microphoneDenied }
        try Task.checkCancellation()

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let capture = AudioCapture()
        try capture.start(format: format) { buffer, level in
            input.yield(AnalyzerInput(buffer: buffer))
            continuation.yield(.level(level))
        }
        session = Session(id: id, capture: capture, analyzer: analyzer, input: input)
        observeInterruptions()
        do {
            try await analyzer.start(inputSequence: inputs)
        } catch {
            await cancel(id: id)
            throw error
        }
        continuation.yield(.recording)

        // Результаты заканчиваются, когда анализатор завершён (`finish()` или отмена).
        var transcript = Transcript()
        for try await result in transcriber.results {
            let text = String(result.text.characters)
            if result.isFinal {
                transcript.finalized = Transcript.join(transcript.finalized, text.trimmingCharacters(in: .whitespaces))
                transcript.volatile = ""
            } else {
                transcript.volatile = text.trimmingCharacters(in: .whitespaces)
            }
            continuation.yield(.transcript(transcript))
        }
        end(id: id)
    }

    /// Транскрайбер с установленной моделью; `nil` — идём запасным путём.
    private func readyTranscriber(
        continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation
    ) async throws -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable else { return nil }
        var locale: Locale?
        for candidate in DictationLocales.candidates {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                locale = supported
                break
            }
        }
        guard let locale else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])
        DictationLog.logger.info(
            "Analyzer: \(locale.identifier, privacy: .public), assets=\(String(describing: status), privacy: .public)"
        )

        switch status {
        case .installed:
            return transcriber
        case .unsupported:
            return nil
        case .supported, .downloading:
            guard connectivity.isOnline else { return nil }
            do {
                try await download(for: transcriber, continuation: continuation)
                return transcriber
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Не скачалось (оборвалась сеть) — пробуем распознать без новой модели.
                return nil
            }
        @unknown default:
            return nil
        }
    }

    private func download(
        for transcriber: SpeechTranscriber,
        continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation
    ) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        continuation.yield(.downloading(fraction: 0))
        let progress = request.progress
        let reporting = Task {
            while !Task.isCancelled {
                continuation.yield(.downloading(fraction: progress.fractionCompleted))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { reporting.cancel() }
        try await request.downloadAndInstall()
    }

    private func end(id: UUID) {
        guard let session, session.id == id else { return }
        session.capture.stop()
        self.session = nil
        interruptions?.cancel()
    }

    private func cancel(id: UUID) async {
        guard let session, session.id == id else { return }
        self.session = nil
        interruptions?.cancel()
        session.capture.stop()
        session.input.finish()
        await session.analyzer.cancelAndFinishNow()
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
}
