import AVFoundation
import Speech

/// Распознавание записи на `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26), на устройстве.
/// Модель языка система скачивает один раз — при первой диктовке, если есть сеть.
/// Без модели и без сети (или если язык не поддерживается) — запасной путь
/// `RecognizerSpeechTranscriber`.
@available(iOS 26, *)
@MainActor
final class AnalyzerSpeechTranscriber: SpeechTranscribing {
    private let connectivity: any ConnectivityMonitoring
    private let fallback: RecognizerSpeechTranscriber

    init(connectivity: any ConnectivityMonitoring) {
        self.connectivity = connectivity
        fallback = RecognizerSpeechTranscriber(connectivity: connectivity)
    }

    /// `SpeechAnalyzer` разрешения на распознавание не требует — спрашиваем его, только
    /// если язык пойдёт запасным путём.
    func prepare() async throws {
        if await Self.locale() == nil { try await fallback.prepare() }
    }

    func transcribe(fileAt url: URL, onDownloadProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        guard let transcriber = try await readyTranscriber(onDownloadProgress: onDownloadProgress) else {
            DictationLog.logger.info("Analyzer: no ready model, using SFSpeechRecognizer")
            return try await fallback.transcribe(fileAt: url, onDownloadProgress: onDownloadProgress)
        }
        do {
            // Результаты читаем параллельно с анализом: поток кончается, когда анализатор дочитал файл.
            let results = Task {
                var text = ""
                for try await result in transcriber.results where result.isFinal {
                    let piece = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                    text = DictationText.join(text, piece)
                }
                return text
            }
            let file = try AVAudioFile(forReading: url)
            let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
            return try await withTaskCancellationHandler {
                try await results.value
            } onCancel: {
                results.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            DictationLog.logger.error("Analyzer: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Первый язык пользователя, который поддерживает `SpeechTranscriber`.
    private static func locale() async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        for candidate in DictationLocales.candidates {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) { return supported }
        }
        return nil
    }

    /// Транскрайбер с установленной моделью; `nil` — идём запасным путём.
    private func readyTranscriber(onDownloadProgress: @escaping @Sendable (Double) -> Void) async throws -> SpeechTranscriber? {
        guard let locale = await Self.locale() else {
            DictationLog.logger.info("Analyzer: unavailable or no supported locale")
            return nil
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
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
                try await download(for: transcriber, onDownloadProgress: onDownloadProgress)
                return transcriber
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Не скачалось (оборвалась сеть) — пробуем распознать без новой модели.
                DictationLog.logger.error("Analyzer: download failed \(String(describing: error), privacy: .public)")
                return nil
            }
        @unknown default:
            return nil
        }
    }

    private func download(
        for transcriber: SpeechTranscriber,
        onDownloadProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        onDownloadProgress(0)
        let progress = request.progress
        let reporting = Task {
            while !Task.isCancelled {
                onDownloadProgress(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { reporting.cancel() }
        try await request.downloadAndInstall()
    }
}
