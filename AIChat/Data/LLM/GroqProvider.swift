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
        // gpt-oss фото не принимает: запрос с фото целиком уходит в vision-модель.
        // У Qwen рассуждения выключаются `reasoning_effort: none`, `include_reasoning` она не знает.
        let hasImages = context.contains { !$0.images.isEmpty }
        let body = RequestBody(
            model: hasImages ? configuration.visionModel : configuration.model,
            messages: context.map { RequestBody.Message($0) },
            stream: true,
            reasoningEffort: hasImages ? "none" : "low",
            includeReasoning: hasImages ? nil : false,
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
            let content: Content
        }

        /// Текст строкой или, если есть фото, массив частей OpenAI-формата:
        /// `[{"type":"text",…}, {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,…"}}]`.
        enum Content: Codable, Equatable, ExpressibleByStringLiteral {
            case text(String)
            case parts([Part])

            struct Part: Codable, Equatable {
                struct ImageURL: Codable, Equatable {
                    let url: String
                }

                let type: String
                var text: String?
                var imageUrl: ImageURL?

                static func text(_ text: String) -> Part { Part(type: "text", text: text) }

                static func jpeg(_ data: Data) -> Part {
                    Part(type: "image_url", imageUrl: ImageURL(url: "data:image/jpeg;base64,\(data.base64EncodedString())"))
                }
            }

            init(stringLiteral value: String) {
                self = .text(value)
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    self = .text(text)
                } else {
                    self = .parts(try container.decode([Part].self))
                }
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case let .text(text): try container.encode(text)
                case let .parts(parts): try container.encode(parts)
                }
            }
        }

        let model: String
        let messages: [Message]
        let stream: Bool
        let reasoningEffort: String
        /// `nil` — не отправляется (vision-модель параметр не поддерживает).
        let includeReasoning: Bool?
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

extension GroqProvider.RequestBody.Message {
    init(_ message: LLMMessage) {
        role = message.role.rawValue
        guard !message.images.isEmpty else {
            content = .text(message.content)
            return
        }
        // Сообщение только с фото — без пустой текстовой части.
        let text = message.content.isEmpty ? [] : [GroqProvider.RequestBody.Content.Part.text(message.content)]
        content = .parts(text + message.images.map(GroqProvider.RequestBody.Content.Part.jpeg))
    }
}
