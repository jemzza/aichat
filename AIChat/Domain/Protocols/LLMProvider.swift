import Foundation

protocol LLMProvider: Sendable {
    /// Подпись под названием чата: «Groq · gpt-oss-120b» / «Offline, on device».
    var displayName: LocalizedStringResource { get }

    /// Дельты текста ответа по мере генерации. Ошибки — `LLMError`.
    ///
    /// Отмена `Task` потребителя прерывает запрос (через `onTermination`), а цикл
    /// `for try await` при этом просто заканчивается **без ошибки** — так ведёт себя
    /// `AsyncThrowingStream`. Отличать «Stop» от нормального конца нужно по `Task.isCancelled`.
    func streamReply(to messages: [LLMMessage]) -> AsyncThrowingStream<String, Error>
}

/// Системная модель на устройстве (Foundation Models, iOS 26): отвечает без сети,
/// но только по кнопке «Answer offline» — автоматически ею не отвечаем.
protocol OnDeviceLLMProvider: LLMProvider {
    /// Модель готова прямо сейчас: устройство поддерживает, Apple Intelligence включён,
    /// модель скачана. Может меняться во время работы — спрашивать перед каждым показом.
    var isAvailable: Bool { get }
}
