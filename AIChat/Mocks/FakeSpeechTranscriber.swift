#if DEBUG
import Foundation

/// Диктовка без микрофона. `.phrase` — «надиктовывает» фразу по словам (для `-mockDictation`);
/// `.manual` — события отдаёт тест (`send`, `complete`); `.fail` — сразу ошибка.
@MainActor
final class FakeSpeechTranscriber: SpeechTranscribing {
    enum Script {
        case manual
        case phrase(String, wordDelay: Duration = .milliseconds(250))
        case fail(Error)
    }

    private let script: Script
    private var continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation?
    private var playback: Task<Void, Never>?
    private(set) var finishCount = 0
    private(set) var dictateCount = 0
    var isActive: Bool { continuation != nil }

    init(script: Script = .manual) {
        self.script = script
    }

    func dictate() -> AsyncThrowingStream<DictationEvent, Error> {
        dictateCount += 1
        let (stream, continuation) = AsyncThrowingStream<DictationEvent, Error>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.playback?.cancel() }
        }
        switch script {
        case .manual:
            self.continuation = continuation
            continuation.yield(.recording)
        case let .phrase(phrase, delay):
            self.continuation = continuation
            continuation.yield(.recording)
            playback = Task { [weak self] in
                var words: [Substring] = []
                for word in phrase.split(separator: " ") {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    words.append(word)
                    continuation.yield(.level(Float.random(in: 0.2...0.9)))
                    continuation.yield(.transcript(Transcript(volatile: words.joined(separator: " "))))
                }
                self?.complete(with: phrase)
            }
        case let .fail(error):
            continuation.finish(throwing: error)
        }
        return stream
    }

    func finish() {
        finishCount += 1
        guard case .phrase = script else { return }
        playback?.cancel()
        continuation?.finish()
        continuation = nil
    }

    /// `.manual`: событие от «распознавателя».
    func send(_ event: DictationEvent) {
        continuation?.yield(event)
    }

    /// Финальный текст и конец сессии.
    func complete(with text: String) {
        continuation?.yield(.transcript(Transcript(finalized: text)))
        continuation?.finish()
        continuation = nil
    }

    func fail(_ error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}
#endif
