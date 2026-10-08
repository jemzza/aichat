import Foundation

struct TimeoutError: Error {}

/// Ждёт первое значение потока, удовлетворяющее условию.
/// Нужен потому, что наблюдение (особенно GRDB) отдаёт значения асинхронно.
func firstValue<Element: Sendable>(
    of stream: AsyncStream<Element>,
    timeout: Duration = .seconds(2),
    where predicate: @escaping @Sendable (Element) -> Bool = { _ in true }
) async throws -> Element {
    try await withThrowingTaskGroup(of: Element?.self) { group in
        group.addTask {
            for await value in stream where predicate(value) { return value }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next(), let value = result else { throw TimeoutError() }
        return value
    }
}

/// Собирает все элементы потока LLM; ошибку возвращает вместе с уже полученным текстом.
func collect(_ stream: AsyncThrowingStream<String, Error>) async -> (text: String, error: (any Error)?) {
    var text = ""
    do {
        for try await token in stream { text += token }
        return (text, nil)
    } catch {
        return (text, error)
    }
}
