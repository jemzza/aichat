import Foundation

/// Groq, OpenAI-совместимый `/chat/completions` со `stream: true`.
///
/// Получает уже собранную историю (фильтрацию и обрезку делают репозиторий и
/// `ChatService`); сам добавляет только системный промпт, если его нет.
struct GroqProvider: LLMProvider {
    static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")
    static let systemPrompt = "Answer in the language of the user's last message. Be concise."
    static let maxCompletionTokens = 1024

    private let configuration: GroqConfiguration
    private let transport: any HTTPLineStreaming

    init(configuration: GroqConfiguration, transport: any HTTPLineStreaming = URLSessionLineStreamer()) {
        self.configuration = configuration
        self.transport = transport
    }

    var displayName: LocalizedStringResource {
        // «openai/gpt-oss-120b» → «gpt-oss-120b».
        let model = configuration.model.split(separator: "/").last.map(String.init) ?? configuration.model
        return "Groq · \(model)"
    }

    func streamReply(to messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        let configuration = configuration
        let transport = transport
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try Self.makeRequest(messages: messages, configuration: configuration)
                    try await Self.run(request, transport: transport) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    // «Stop» — не ошибка: поток просто заканчивается.
                    if Task.isCancelled {
                        continuation.finish()
                    } else if let llmError = GroqErrorMapper.map(error) {
                        continuation.finish(throwing: llmError)
                    } else {
                        continuation.finish()
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Запрос

    static func makeRequest(messages: [LLMMessage], configuration: GroqConfiguration) throws -> URLRequest {
        // Пустой ключ (не сгенерирован `Secrets`) — сразу 401, без запроса в сеть.
        guard configuration.hasAPIKey else { throw LLMError(kind: .unauthorized) }
        guard let endpoint else { throw LLMError(kind: .unknown) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        var context = messages
        if context.first?.role != .system {
            context.insert(LLMMessage(role: .system, content: systemPrompt), at: 0)
        }
        let body = RequestBody(
            model: configuration.model,
            messages: context.map { .init(role: $0.role.rawValue, content: $0.content) },
            stream: true,
            reasoningEffort: "low",
            includeReasoning: false,
            maxCompletionTokens: maxCompletionTokens
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)
        return request
    }

    struct RequestBody: Codable, Equatable {
        struct Message: Codable, Equatable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let stream: Bool
        let reasoningEffort: String
        let includeReasoning: Bool
        let maxCompletionTokens: Int
    }

    // MARK: - Ответ

    /// Сколько символов тела ошибки дочитываем при HTTP ≠ 200.
    static let errorBodyLimit = 4096

    private static func run(
        _ request: URLRequest,
        transport: any HTTPLineStreaming,
        emit: (String) -> Void
    ) async throws {
        var head: HTTPResponseHead?
        var errorBody = ""
        reading: for try await event in transport.stream(request) {
            switch event {
            case let .head(responseHead):
                head = responseHead
            case let .line(line):
                guard let head else { continue }
                if head.statusCode != 200 {
                    // Тело ошибки дочитываем ограниченно: нужен только `{"error": …}`.
                    errorBody += line + "\n"
                    if errorBody.count >= errorBodyLimit { break reading }
                    continue
                }
                switch SSEParser.parse(line: line) {
                case let .delta(text): emit(text)
                case .done: return
                case let .error(payload): throw GroqErrorMapper.map(streamError: payload)
                case nil: continue
                }
            }
        }
        try Task.checkCancellation()
        if let head, head.statusCode != 200 {
            throw GroqErrorMapper.map(head: head, payload: GroqErrorMapper.payload(fromBody: errorBody))
        }
        // Соединение закрылось без `[DONE]` — ответ, скорее всего, обрезан.
        throw LLMError(kind: .unknown)
    }
}
