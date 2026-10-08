#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Системная модель Apple Intelligence (iOS 26): ответ без сети по кнопке «Answer offline».
/// Тот же контракт, что у `GroqProvider`: дельты текста, отмена — не ошибка.
@available(iOS 26, *)
struct FoundationModelsProvider: OnDeviceLLMProvider {
    /// Как у Groq: длинные ответы маленькой модели всё равно хуже.
    static let maximumResponseTokens = 1024

    var displayName: LocalizedStringResource { "Offline, on device" }

    var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    func streamReply(to messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        let request = OnDevicePrompt(messages: messages)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard SystemLanguageModel.default.isAvailable else { throw LLMError(kind: .unknown) }
                    let session = LanguageModelSession(instructions: request.instructions)
                    let options = GenerationOptions(maximumResponseTokens: Self.maximumResponseTokens)
                    var emitted = ""
                    for try await snapshot in session.streamResponse(to: request.prompt, options: options) {
                        // Снимок, который переписал начало (у строкового ответа не бывает), пропускаем:
                        // дельтами его не выразить, а следующий снимок продолжит уже отданный текст.
                        guard let delta = OnDevicePrompt.delta(from: emitted, to: snapshot.content) else { continue }
                        emitted = snapshot.content
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    // «Stop» — не ошибка: поток просто заканчивается.
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Self.map(error))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func map(_ error: any Error) -> LLMError {
        if let error = error as? LLMError { return error }
        guard let error = error as? LanguageModelSession.GenerationError else { return LLMError(kind: .unknown) }
        switch error {
        case .unsupportedLanguageOrLocale:
            return LLMError(kind: .unsupportedLanguage)
        case .rateLimited, .concurrentRequests:
            return LLMError(kind: .rateLimited)
        default:
            // Контекст не влез, отказ модели, guardrails, модель не скачана — «Something went wrong».
            return LLMError(kind: .unknown)
        }
    }
}
#endif
