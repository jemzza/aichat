#if DEBUG
import Foundation
import Synchronization

/// LLM по сценарию: отдаёт текст по словам с паузой, падает или «висит» до отмены.
final class FakeLLMProvider: LLMProvider {
    enum Script: Hashable, Sendable {
        /// Весь текст по словам, с паузой перед каждым.
        case reply(String, tokenDelay: Duration = .milliseconds(30))
        /// Сначала `partialText`, потом ошибка.
        case fail(LLMError, partialText: String = "", tokenDelay: Duration = .milliseconds(30))
        /// Ничего не отдаёт, пока потребитель не отменит `Task` (проверка «Stop»).
        case hang
    }

    let displayName: LocalizedStringResource = "Mock model"

    private struct State {
        var script: Script
        var requests: [[LLMMessage]] = []
    }

    private let state: Mutex<State>

    init(script: Script = .reply("Hello! This is a **mock** reply.")) {
        state = Mutex(State(script: script))
    }

    /// Все запросы, которые пришли в провайдер, — для проверок в тестах.
    var requests: [[LLMMessage]] { state.withLock(\.requests) }

    func setScript(_ script: Script) {
        state.withLock { $0.script = script }
    }

    func streamReply(to messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        let script = state.withLock { state in
            state.requests.append(messages)
            return state.script
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.play(script) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func play(_ script: Script, emit: (String) -> Void) async throws {
        switch script {
        case let .reply(text, delay):
            try await emitTokens(of: text, delay: delay, emit: emit)
        case let .fail(error, partialText, delay):
            try await emitTokens(of: partialText, delay: delay, emit: emit)
            throw error
        case .hang:
            while true { try await Task.sleep(for: .seconds(60)) }
        }
    }

    private static func emitTokens(of text: String, delay: Duration, emit: (String) -> Void) async throws {
        for token in tokens(of: text) {
            try await Task.sleep(for: delay)
            emit(token)
        }
    }

    /// Слова вместе с пробелом/переводом строки после них — склейка даёт исходный текст.
    static func tokens(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " || character == "\n" {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
#endif
