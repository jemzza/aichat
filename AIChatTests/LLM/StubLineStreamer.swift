import Foundation
import Synchronization
@testable import AIChat

/// Транспорт по сценарию: отдаёт заданные события, потом заканчивает поток,
/// бросает ошибку или «висит» до отмены. Запоминает запросы и факт отмены.
final class StubLineStreamer: HTTPLineStreaming {
    enum Ending: Sendable {
        case finish
        case fail(any Error)
        case hang
    }

    private struct State {
        var requests: [URLRequest] = []
        var terminatedEarly = false
    }

    private let events: [HTTPStreamEvent]
    private let ending: Ending
    private let state = Mutex(State())

    init(events: [HTTPStreamEvent], ending: Ending = .finish) {
        self.events = events
        self.ending = ending
    }

    /// 200 и строки SSE.
    convenience init(sse lines: [String], ending: Ending = .finish) {
        self.init(events: [.head(HTTPResponseHead(statusCode: 200))] + lines.map(HTTPStreamEvent.line), ending: ending)
    }

    var requests: [URLRequest] { state.withLock(\.requests) }
    /// Потребитель бросил поток до его конца (отмена или `break`).
    var terminatedEarly: Bool { state.withLock(\.terminatedEarly) }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        state.withLock { $0.requests.append(request) }
        let events = events
        let ending = ending
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in events {
                    continuation.yield(event)
                    await Task.yield()
                }
                switch ending {
                case .finish:
                    continuation.finish()
                case let .fail(error):
                    continuation.finish(throwing: error)
                case .hang:
                    while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
                }
            }
            continuation.onTermination = { [self] termination in
                if case .cancelled = termination {
                    state.withLock { $0.terminatedEarly = true }
                }
                task.cancel()
            }
        }
    }
}
