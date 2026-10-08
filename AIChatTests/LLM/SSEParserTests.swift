import Testing
@testable import AIChat

struct SSEParserTests {
    private func chunk(_ content: String) -> String {
        #"data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"\#(content)"},"finish_reason":null}]}"#
    }

    // MARK: - Дельты

    @Test func parsesContentDelta() {
        #expect(SSEParser.parse(line: chunk("Hello")) == .delta("Hello"))
    }

    @Test func keepsLeadingSpaceAndEscapesInsideContent() {
        #expect(SSEParser.parse(line: chunk(#" world\n\"q\" é"#)) == .delta(" world\n\"q\" é"))
    }

    @Test func acceptsDataWithoutSpaceAfterColon() {
        let line = #"data:{"choices":[{"delta":{"content":"x"}}]}"#
        #expect(SSEParser.parse(line: line) == .delta("x"))
    }

    @Test func stripsTrailingCarriageReturn() {
        #expect(SSEParser.parse(line: chunk("Hi") + "\r") == .delta("Hi"))
        #expect(SSEParser.parse(line: "data: [DONE]\r") == .done)
    }

    @Test(arguments: [
        // Первый чанк: только роль, без текста.
        #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":null}}]}"#,
        #"data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}"#,
        // Пустой текст.
        #"data: {"choices":[{"index":0,"delta":{"content":""}}]}"#,
        // Последний чанк Groq: пустые choices + статистика.
        #"data: {"choices":[],"x_groq":{"id":"req_1","usage":{"total_tokens":10}}}"#,
        // Конец генерации без текста.
        #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
    ])
    func ignoresChunksWithoutText(line: String) {
        #expect(SSEParser.parse(line: line) == nil)
    }

    // MARK: - [DONE]

    @Test(arguments: ["data: [DONE]", "data:[DONE]", "data: [DONE]  "])
    func recognizesDone(line: String) {
        #expect(SSEParser.parse(line: line) == .done)
    }

    // MARK: - Пустые data: и служебные строки

    @Test(arguments: ["", "data:", "data: ", "data:   ", ": keep-alive", ":", "event: message", "id: 42", "retry: 1000"])
    func ignoresEmptyAndServiceLines(line: String) {
        #expect(SSEParser.parse(line: line) == nil)
    }

    // MARK: - Обрезанные строки, не-JSON и мусор

    @Test(arguments: [
        #"data: {"choices":[{"delta":{"content":"Hel"#,
        #"data: {"choices":[{"delta":"#,
        #"data: {"#,
        #"{"choices":[{"delta":{"content":"no prefix"}}]}"#,
        "data: hello",
        "data: 42",
        "data: [\"array\"]",
        "data: null",
        "dat",
        "garbage \u{0}\u{1}",
        #"data: {"unexpected":"shape"}"#,
    ])
    func ignoresTruncatedAndNonJSONLines(line: String) {
        #expect(SSEParser.parse(line: line) == nil)
    }

    // MARK: - Ошибка внутри data:

    @Test func parsesErrorPayload() {
        let line = #"data: {"error":{"message":"Rate limit reached","type":"tokens","code":"rate_limit_exceeded"}}"#
        #expect(SSEParser.parse(line: line) == .error(StreamErrorPayload(type: "tokens", code: "rate_limit_exceeded")))
    }

    @Test func parsesErrorPayloadWithoutTypeAndCode() {
        let line = #"data: {"error":{"message":"Something broke","type":null}}"#
        #expect(SSEParser.parse(line: line) == .error(StreamErrorPayload(type: nil, code: nil)))
    }

    /// Текст ошибки сервера в событие не попадает — он не должен дойти до UI.
    @Test func errorPayloadDoesNotKeepServerMessage() {
        let line = #"data: {"error":{"message":"secret details","type":"server_error"}}"#
        let event = SSEParser.parse(line: line)
        #expect(!String(describing: event).contains("secret details"))
    }

    // MARK: - Поток целиком

    @Test func parsesTypicalGroqStream() {
        let lines = [
            #"data: {"choices":[{"delta":{"role":"assistant","content":""}}]}"#,
            "",
            chunk("Hel"),
            "",
            chunk("lo"),
            ": ping",
            chunk("!"),
            #"data: {"choices":[],"x_groq":{"usage":{}}}"#,
            "data: [DONE]",
        ]
        let events = lines.compactMap(SSEParser.parse(line:))
        #expect(events == [.delta("Hel"), .delta("lo"), .delta("!"), .done])
    }
}
