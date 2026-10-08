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

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimeoutError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
