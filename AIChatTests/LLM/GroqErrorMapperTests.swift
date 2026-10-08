import Foundation
import Testing
@testable import AIChat

struct GroqErrorMapperTests {
    // MARK: - Отмена ≠ ошибка

    @Test func cancellationIsNotAnError() {
        #expect(GroqErrorMapper.map(CancellationError()) == nil)
        #expect(GroqErrorMapper.map(URLError(.cancelled)) == nil)
    }

    // MARK: - URLError

    @Test(arguments: [
        URLError.Code.notConnectedToInternet,
        .networkConnectionLost,
        .dataNotAllowed,
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
    ])
    func offlineURLErrors(code: URLError.Code) {
        #expect(GroqErrorMapper.map(URLError(code))?.kind == .offline)
    }

    @Test(arguments: [
        URLError.Code.badServerResponse,
        .secureConnectionFailed,
        .serverCertificateUntrusted,
        .badURL,
        .cannotDecodeContentData,
    ])
    func otherURLErrorsAreUnknown(code: URLError.Code) {
        #expect(GroqErrorMapper.map(URLError(code))?.kind == .unknown)
    }

    @Test func llmErrorPassesThrough() {
        let error = LLMError(kind: .rateLimited, retryAfter: .seconds(3))
        #expect(GroqErrorMapper.map(error) == error)
    }

    @Test func foreignErrorIsUnknown() {
        struct Foreign: Error {}
        #expect(GroqErrorMapper.map(Foreign())?.kind == .unknown)
    }

    // MARK: - HTTP-коды

    @Test(arguments: [
        (401, ErrorKind.unauthorized),
        (403, .forbidden),
        (429, .rateLimited),
        (500, .server),
        (502, .server),
        (503, .server),
        (599, .server),
        (400, .unknown),
        (404, .unknown),
        (413, .unknown),
    ])
    func mapsStatusCodes(status: Int, kind: ErrorKind) {
        #expect(GroqErrorMapper.map(head: HTTPResponseHead(statusCode: status), payload: nil).kind == kind)
    }

    @Test func rateLimitReadsRetryAfterCaseInsensitively() {
        let head = HTTPResponseHead(statusCode: 429, headers: ["Retry-After": "12"])
        let error = GroqErrorMapper.map(head: head, payload: nil)
        #expect(error == LLMError(kind: .rateLimited, retryAfter: .seconds(12)))
    }

    @Test func rateLimitWithoutRetryAfter() {
        let error = GroqErrorMapper.map(head: HTTPResponseHead(statusCode: 429), payload: nil)
        #expect(error == LLMError(kind: .rateLimited, retryAfter: nil))
    }

    /// Код важнее тела: 403 остаётся `forbidden`, даже если в теле что-то другое.
    @Test func statusCodeWinsOverPayload() {
        let payload = StreamErrorPayload(type: "tokens", code: "rate_limit_exceeded")
        #expect(GroqErrorMapper.map(head: HTTPResponseHead(statusCode: 403), payload: payload).kind == .forbidden)
    }

    /// Для кодов вне таблицы смотрим на тело.
    @Test func unknownStatusFallsBackToPayload() {
        let payload = StreamErrorPayload(type: "invalid_request_error", code: "invalid_api_key")
        #expect(GroqErrorMapper.map(head: HTTPResponseHead(statusCode: 400), payload: payload).kind == .unauthorized)
    }

    // MARK: - retry-after

    @Test(arguments: [
        ("12", Duration.seconds(12)),
        (" 7 ", .seconds(7)),
        ("1.5", .milliseconds(1500)),
        ("0", .zero),
        ("-3", .zero),
    ])
    func parsesRetryAfterSeconds(value: String, expected: Duration) {
        #expect(GroqErrorMapper.retryAfter(value) == expected)
    }

    @Test(arguments: [nil, "", "soon", "nan", "inf", "Sun, 09 Sep 2001 01:47:10 GMT"])
    func ignoresInvalidRetryAfter(value: String?) {
        #expect(GroqErrorMapper.retryAfter(value) == nil)
    }

    // MARK: - Ошибка внутри SSE при HTTP 200

    @Test(arguments: [
        (StreamErrorPayload(type: "tokens", code: "rate_limit_exceeded"), ErrorKind.rateLimited),
        (StreamErrorPayload(type: "requests", code: nil), .rateLimited),
        (StreamErrorPayload(type: "invalid_request_error", code: "invalid_api_key"), .unauthorized),
        (StreamErrorPayload(type: "permission_denied", code: nil), .forbidden),
        (StreamErrorPayload(type: "server_error", code: nil), .server),
        (StreamErrorPayload(type: "internal_server_error", code: "SERVICE_UNAVAILABLE"), .server),
        (StreamErrorPayload(type: "something_new", code: "weird"), .server),
        (StreamErrorPayload(type: nil, code: nil), .server),
    ])
    func mapsStreamErrors(payload: StreamErrorPayload, kind: ErrorKind) {
        #expect(GroqErrorMapper.map(streamError: payload).kind == kind)
    }

    @Test func parsesPayloadFromBody() {
        let body = #"{"error":{"message":"Invalid API Key","type":"invalid_request_error","code":"invalid_api_key"}}"#
        #expect(GroqErrorMapper.payload(fromBody: body) == StreamErrorPayload(type: "invalid_request_error", code: "invalid_api_key"))
        #expect(GroqErrorMapper.payload(fromBody: "<html>Bad gateway</html>") == nil)
        #expect(GroqErrorMapper.payload(fromBody: "") == nil)
    }
}
