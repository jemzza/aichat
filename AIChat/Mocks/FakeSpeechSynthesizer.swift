#if DEBUG
import Foundation

/// Озвучка без звука: запоминает, что просили прочитать; закончить чтение — `finish()`.
@MainActor
final class FakeSpeechSynthesizer: SpeechSynthesizing {
    private(set) var spoken: [(text: String, messageId: UUID)] = []
    private(set) var stopCount = 0
    private(set) var playback = SpeechPlayback.idle {
        didSet { for continuation in continuations { continuation.yield(playback) } }
    }
    private var continuations: [AsyncStream<SpeechPlayback>.Continuation] = []

    func playbackUpdates() -> AsyncStream<SpeechPlayback> {
        let (stream, continuation) = AsyncStream<SpeechPlayback>.makeStream()
        continuation.yield(playback)
        continuations.append(continuation)
        return stream
    }

    func speak(_ text: String, messageId: UUID) {
        spoken.append((text, messageId))
        playback = .speaking(messageId: messageId)
    }

    func stop() {
        stopCount += 1
        playback = .idle
    }

    /// Чтение закончилось само.
    func finish() {
        playback = .idle
    }
}
#endif
