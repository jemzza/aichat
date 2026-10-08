import AVFoundation

/// Запись голоса на `AVAudioRecorder` во временный файл: PCM 16 кГц моно — этот формат
/// понимают оба распознавателя. Файл удаляется после распознавания; остатки после
/// аварийного завершения — при создании рекордера (на старте приложения).
@MainActor
final class SystemVoiceRecorder: VoiceRecording {
    /// Серверный `SFSpeechRecognizer` распознаёт около минуты за запрос.
    static let maximumDuration: TimeInterval = 60
    private static let filePrefix = "dictation-"

    private var recorder: AVAudioRecorder?
    private var monitor: Task<Void, Never>?
    private var interruptions: Task<Void, Never>?

    init() {
        Self.removeLeftovers()
    }

    func requestPermission() async -> Bool {
        await MicrophonePermission.request()
    }

    func start() throws -> AsyncStream<RecordingEvent> {
        cancel()
        let session = AVAudioSession.sharedInstance()
        // `.default`, а не `.measurement`: со включённой автоподстройкой усиления тихую речь
        // распознаёт лучше. `.duckOthers` приглушает музыку на время записи.
        try session.setCategory(.record, mode: .default, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(Self.filePrefix)\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            deactivateSession()
            DictationLog.logger.error("Recorder: init failed \(String(describing: error), privacy: .public)")
            throw error
        }
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: Self.maximumDuration) else {
            deactivateSession()
            DictationLog.logger.error("Recorder: record() returned false")
            throw RecorderError.couldNotStart
        }
        self.recorder = recorder
        DictationLog.logger.info("Recorder: started")

        let (stream, continuation) = AsyncStream<RecordingEvent>.makeStream()
        monitor = Task { [weak recorder] in
            while !Task.isCancelled, let recorder {
                guard recorder.isRecording else {
                    // Остановилась сама: лимит длительности или прерывание.
                    continuation.yield(.stoppedAutomatically)
                    break
                }
                recorder.updateMeters()
                continuation.yield(.progress(duration: .seconds(recorder.currentTime),
                                             level: Self.level(decibels: recorder.averagePower(forChannel: 0))))
                try? await Task.sleep(for: .milliseconds(100))
            }
            continuation.finish()
        }
        interruptions = Task { [weak recorder] in
            await AudioInterruptions.first()
            guard !Task.isCancelled else { return }
            recorder?.stop()
        }
        return stream
    }

    func stop() -> URL? {
        guard let recorder else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        finishSession()
        let url = recorder.url
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        DictationLog.logger.info(
            "Recorder: stopped, \(duration, format: .fixed(precision: 1), privacy: .public) s, \(size, privacy: .public) bytes"
        )
        return url
    }

    func cancel() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        finishSession()
    }

    func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func finishSession() {
        monitor?.cancel()
        interruptions?.cancel()
        monitor = nil
        interruptions = nil
        recorder = nil
        deactivateSession()
    }

    private func deactivateSession() {
        // Музыка других приложений снова звучит в полную громкость.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// −50…0 дБ → 0…1.
    private static func level(decibels: Float) -> Float {
        min(max((decibels + 50) / 50, 0), 1)
    }

    private static func removeLeftovers() {
        let directory = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(filePrefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

enum RecorderError: Error {
    case couldNotStart
}
