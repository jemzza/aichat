import Foundation

/// Код и заголовки ответа. Своя `Sendable`-структура вместо `HTTPURLResponse`,
/// чтобы спокойно передавать её между задачами.
struct HTTPResponseHead: Hashable, Sendable {
    let statusCode: Int
    /// Имена заголовков в нижнем регистре.
    let headers: [String: String]

    init(statusCode: Int, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    func value(forHeader name: String) -> String? {
        headers[name.lowercased()]
    }
}

enum HTTPStreamEvent: Hashable, Sendable {
    /// Всегда первое событие.
    case head(HTTPResponseHead)
    /// Строка тела без перевода строки.
    case line(String)
}

/// Транспорт для стриминга: отдаёт заголовок ответа, затем тело построчно.
/// Отмена потребителя (или `break` из цикла) должна прерывать запрос.
protocol HTTPLineStreaming: Sendable {
    func stream(_ request: URLRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error>
}

/// Живая реализация на `URLSession.bytes(for:)`.
struct URLSessionLineStreamer: HTTPLineStreaming {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
                        if let name = field.key as? String, let value = field.value as? String {
                            result[name] = value
                        }
                    }
                    continuation.yield(.head(HTTPResponseHead(statusCode: http.statusCode, headers: headers)))
                    for try await line in bytes.lines {
                        continuation.yield(.line(line))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
