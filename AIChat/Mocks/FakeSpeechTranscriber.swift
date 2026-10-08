#if DEBUG
import Foundation

/// Распознавание без Speech: возвращает заданный текст (или ошибку) после задержки.
@MainActor
final class FakeSpeechTranscriber: SpeechTranscribing {
    var result: Result<String, Error>
    var prepareError: Error?
    var delay: Duration
    /// Перед результатом «скачивает модель» с этими долями.
    var downloadSteps: [Double] = []
    private(set) var transcribedFiles: [URL] = []

    init(result: Result<String, Error> = .success(""), delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    func prepare() async throws {
        if let prepareError { throw prepareError }
    }

    func transcribe(fileAt url: URL, onDownloadProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        transcribedFiles.append(url)
        for step in downloadSteps { onDownloadProgress(step) }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}
#endif
