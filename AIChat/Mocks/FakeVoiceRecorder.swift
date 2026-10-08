#if DEBUG
import Foundation

/// Запись без микрофона. По умолчанию сама шлёт `.progress` каждые 100 мс со случайной
/// громкостью (для `-mockDictation`); в тестах события можно слать вручную (`send`).
@MainActor
final class FakeVoiceRecorder: VoiceRecording {
    var isPermissionGranted = true
    var startError: Error?
    /// `false` — события только через `send` (тесты).
    var ticks: Bool

    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var discarded: [URL] = []
    private(set) var isRecording = false
    private var continuation: AsyncStream<RecordingEvent>.Continuation?
    private var ticking: Task<Void, Never>?
    private var currentURL: URL?

    init(ticks: Bool = true) {
        self.ticks = ticks
    }

    func requestPermission() async -> Bool {
        isPermissionGranted
    }

    func start() throws -> AsyncStream<RecordingEvent> {
        if let startError { throw startError }
        startCount += 1
        isRecording = true
        currentURL = FileManager.default.temporaryDirectory.appending(path: "fake-dictation-\(startCount).caf")
        let (stream, continuation) = AsyncStream<RecordingEvent>.makeStream()
        self.continuation = continuation
        if ticks {
            ticking = Task {
                let started = ContinuousClock.now
                while !Task.isCancelled {
                    continuation.yield(.progress(duration: ContinuousClock.now - started, level: .random(in: 0.2...0.9)))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        return stream
    }

    func stop() -> URL? {
        guard isRecording else { return nil }
        finishRecording()
        return currentURL
    }

    func cancel() {
        cancelCount += 1
        finishRecording()
    }

    func discard(_ url: URL) {
        discarded.append(url)
    }

    /// Событие от «микрофона».
    func send(_ event: RecordingEvent) {
        continuation?.yield(event)
    }

    private func finishRecording() {
        isRecording = false
        ticking?.cancel()
        continuation?.finish()
        continuation = nil
    }
}
#endif
