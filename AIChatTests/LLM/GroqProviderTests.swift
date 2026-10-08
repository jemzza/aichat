import Foundation
import Testing
@testable import AIChat

struct GroqProviderTests {
    /// Синтетический ключ: настоящий в тестах не используется.
    private let configuration = GroqConfiguration(apiKey: "test-key", model: "openai/gpt-oss-120b")

    private func chunk(_ content: String) -> String {
        #"data: {"choices":[{"index":0,"delta":{"content":"\#(content)"}}]}"#
    }

    private func body(of request: URLRequest) throws -> GroqProvider.RequestBody {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GroqProvider.RequestBody.self, from: try #require(request.httpBody))
    }

    // MARK: - Запрос

    @Test func buildsStreamingRequest() throws {
        let messages = [
            LLMMessage(role: .user, content: "Hi"),
            LLMMessage(role: .assistant, content: "Hello!"),
            LLMMessage(role: .user, content: "How are you?"),
        ]
        let request = try GroqProvider.makeRequest(messages: messages, configuration: configuration)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")

        let body = try body(of: request)
        #expect(body.model == "openai/gpt-oss-120b")
        #expect(body.stream)
        #expect(body.reasoningEffort == "low")
        #expect(body.includeReasoning == false)
        #expect(body.maxCompletionTokens == 1024)
        #expect(body.messages.map(\.role) == ["system", "user", "assistant", "user"])
        #expect(body.messages.first?.content == GroqProvider.systemPrompt)
        #expect(body.messages.dropFirst().map(\.content) == ["Hi", "Hello!", "How are you?"])
    }

    @Test func bodyUsesSnakeCaseKeys() throws {
        let request = try GroqProvider.makeRequest(messages: [], configuration: configuration)
        let data = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["model", "messages", "stream", "reasoning_effort", "include_reasoning", "max_completion_tokens"])
    }

    @Test func keepsCallerSystemPrompt() throws {
        let messages = [LLMMessage(role: .system, content: "Custom"), LLMMessage(role: .user, content: "Hi")]
        let body = try body(of: GroqProvider.makeRequest(messages: messages, configuration: configuration))
        #expect(body.messages.map(\.content) == ["Custom", "Hi"])
    }

    @Test func displayNameShowsShortModelName() {
        let provider = GroqProvider(configuration: configuration, transport: StubLineStreamer(sse: []))
        #expect(String(localized: provider.displayName) == "Groq · gpt-oss-120b")
    }

    // MARK: - Стриминг

    @Test func streamsDeltasUntilDone() async {
        let transport = StubLineStreamer(sse: [
            #"data: {"choices":[{"delta":{"role":"assistant","content":""}}]}"#,
            chunk("Hel"),
            ": ping",
            chunk("lo"),
            "garbage",
            chunk(" world"),
            "data: [DONE]",
        ])
        let provider = GroqProvider(configuration: configuration, transport: transport)

        let result = await collect(provider.streamReply(to: [LLMMessage(role: .user, content: "Hi")]))

        #expect(result.text == "Hello world")
        #expect(result.error == nil)
        #expect(transport.requests.count == 1)
    }

    /// После `[DONE]` дальше не читаем.
    @Test func ignoresLinesAfterDone() async {
        let transport = StubLineStreamer(sse: [chunk("A"), "data: [DONE]", chunk("B")], ending: .hang)
        let provider = GroqProvider(configuration: configuration, transport: transport)

        let result = await collect(provider.streamReply(to: []))

        #expect(result.text == "A")
        #expect(result.error == nil)
    }

    /// Соединение закрылось без `[DONE]` — это ошибка, а не тихо обрезанный ответ.
    @Test func endWithoutDoneIsError() async {
        let provider = GroqProvider(configuration: configuration, transport: StubLineStreamer(sse: [chunk("Half")]))

        let result = await collect(provider.streamReply(to: []))

        #expect(result.text == "Half")
        #expect(result.error is LLMError)
    }

    // MARK: - Отмена

    @Test func cancellationFinishesWithoutErrorAndAbortsRequest() async throws {
        let transport = StubLineStreamer(sse: [chunk("Partial")], ending: .hang)
        let provider = GroqProvider(configuration: configuration, transport: transport)
        let task = Task {
            let result = await collect(provider.streamReply(to: []))
            return (result, Task.isCancelled)
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let (result, wasCancelled) = await task.value

        #expect(result.error == nil)
        #expect(wasCancelled)
        // Запрос к транспорту прерван, а не брошен висеть.
        try await waitUntil { transport.terminatedEarly }
    }

    /// Обрыв посреди ответа: полученный текст остаётся у потребителя, затем ошибка.
    @Test func transportFailureKeepsReceivedText() async {
        let transport = StubLineStreamer(sse: [chunk("Partial")], ending: .fail(URLError(.networkConnectionLost)))
        let provider = GroqProvider(configuration: configuration, transport: transport)

        let result = await collect(provider.streamReply(to: []))

        #expect(result.text == "Partial")
        #expect(result.error != nil)
    }

    // MARK: - Ошибки

    @Test func missingKeyIsUnauthorizedWithoutRequest() async {
        let transport = StubLineStreamer(sse: ["data: [DONE]"])
        let provider = GroqProvider(configuration: GroqConfiguration(apiKey: "", model: "m"), transport: transport)

        let result = await collect(provider.streamReply(to: []))

        #expect(result.error as? LLMError == LLMError(kind: .unauthorized))
        #expect(transport.requests.isEmpty)
    }

    @Test(arguments: [
        (401, ErrorKind.unauthorized),
        (403, .forbidden),
        (500, .server),
        (503, .server),
        (418, .unknown),
    ])
    func httpStatusIsMapped(status: Int, kind: ErrorKind) async {
        let transport = StubLineStreamer(events: [
            .head(HTTPResponseHead(statusCode: status)),
            .line(#"{"error":{"message":"details","type":"x"}}"#),
        ])
        let provider = GroqProvider(configuration: configuration, transport: transport)

        let result = await collect(provider.streamReply(to: []))

        #expect(result.text.isEmpty)
        #expect((result.error as? LLMError)?.kind == kind)
    }

    @Test func rateLimitCarriesRetryAfter() async {
        let transport = StubLineStreamer(events: [
            .head(HTTPResponseHead(statusCode: 429, headers: ["retry-after": "17"])),
            .line(#"{"error":{"message":"Rate limit reached","type":"tokens","code":"rate_limit_exceeded"}}"#),
        ])
        let provider = GroqProvider(configuration: configuration, transport: transport)

        let result = await collect(provider.streamReply(to: []))

        #expect(result.error as? LLMError == LLMError(kind: .rateLimited, retryAfter: .seconds(17)))
    }

    /// Тело ошибки читаем ограниченно: бесконечное тело не держит запрос.
    @Test func errorBodyIsReadWithLimit() async throws {
        let longLine = String(repeating: "x", count: GroqProvider.errorBodyLimit)
        let transport = StubLineStreamer(
            events: [.head(HTTPResponseHead(statusCode: 502)), .line(longLine)],
            ending: .hang
        )
        let provider = GroqProvider(configuration: configuration, transport: transport)

        let result = await collect(provider.streamReply(to: []))

        #expect((result.error as? LLMError)?.kind == .server)
        try await waitUntil { transport.terminatedEarly }
    }

    /// Ошибка внутри SSE при HTTP 200: полученный текст остаётся, ошибка — по `type`/`code`.
    @Test func streamErrorAfterPartialText() async {
        let transport = StubLineStreamer(sse: [
            chunk("Partial"),
            #"data: {"error":{"message":"Rate limit reached","type":"tokens","code":"rate_limit_exceeded"}}"#,
            chunk("never"),
        ])
        let provider = GroqProvider(configuration: configuration, transport: transport)

        let result = await collect(provider.streamReply(to: []))

        #expect(result.text == "Partial")
        #expect((result.error as? LLMError)?.kind == .rateLimited)
    }

    @Test func unknownStreamErrorIsServer() async {
        let transport = StubLineStreamer(sse: [#"data: {"error":{"message":"oops"}}"#])
        let provider = GroqProvider(configuration: configuration, transport: transport)

        let result = await collect(provider.streamReply(to: []))

        #expect((result.error as? LLMError)?.kind == .server)
    }

    @Test func offlineTransportError() async {
        let transport = StubLineStreamer(events: [], ending: .fail(URLError(.notConnectedToInternet)))
        let provider = GroqProvider(configuration: configuration, transport: transport)

        let result = await collect(provider.streamReply(to: []))

        #expect(result.error as? LLMError == LLMError(kind: .offline))
    }

    /// `URLError.cancelled` от транспорта — это «Stop», не «нет сети».
    @Test func urlCancelledIsNotOffline() async {
        let transport = StubLineStreamer(sse: [chunk("Part")], ending: .fail(URLError(.cancelled)))
        let provider = GroqProvider(configuration: configuration, transport: transport)

        let result = await collect(provider.streamReply(to: []))

        #expect(result.text == "Part")
        #expect(result.error == nil)
    }

    /// В ошибке нет ни ключа, ни текста ответа сервера.
    @Test func errorDoesNotLeakDetails() async {
        let transport = StubLineStreamer(events: [
            .head(HTTPResponseHead(statusCode: 401)),
            .line(#"{"error":{"message":"server secret details","code":"invalid_api_key"}}"#),
        ])
        let provider = GroqProvider(configuration: configuration, transport: transport)

        let result = await collect(provider.streamReply(to: []))
        let description = String(reflecting: result.error)

        #expect(!description.contains("test-key"))
        #expect(!description.contains("secret details"))
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimeoutError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
