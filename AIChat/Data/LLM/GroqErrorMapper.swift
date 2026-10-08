import Foundation

/// Маппинг ошибок Groq в `LLMError` по таблице «Маппинг ошибок» из `docs/task.md`.
/// Никогда не переносит в ошибку текст ответа сервера, URL или ключ — только `ErrorKind`.
enum GroqErrorMapper {
    /// `URLError`, которые означают «нет сети»; прочие — `unknown`.
    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .dataNotAllowed,
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
    ]

    /// Ошибка транспорта или парсинга. `nil` — это отмена («Stop»), а не ошибка.
    static func map(_ error: any Error) -> LLMError? {
        switch error {
        case let error as LLMError:
            return error
        case is CancellationError:
            return nil
        case let error as URLError where error.code == .cancelled:
            return nil
        case let error as URLError:
            return LLMError(kind: offlineCodes.contains(error.code) ? .offline : .unknown)
        default:
            return LLMError(kind: .unknown)
        }
    }

    /// Ответ с кодом ≠ 200. `payload` — ошибка из тела, если её удалось разобрать.
    static func map(head: HTTPResponseHead, payload: StreamErrorPayload?) -> LLMError {
        switch head.statusCode {
        case 401:
            return LLMError(kind: .unauthorized)
        case 403:
            return LLMError(kind: .forbidden)
        case 429:
            return LLMError(kind: .rateLimited, retryAfter: retryAfter(head.value(forHeader: "retry-after")))
        case 500...599:
            return LLMError(kind: .server)
        default:
            return LLMError(kind: payload.flatMap(classify) ?? .unknown)
        }
    }

    /// `data: {"error": …}` при HTTP 200: по `type`/`code`, иначе `server`.
    static func map(streamError payload: StreamErrorPayload) -> LLMError {
        LLMError(kind: classify(payload) ?? .server)
    }

    /// Ошибка из тела ответа (`{"error": {...}}`); `nil`, если тело не такого вида.
    static func payload(fromBody body: String) -> StreamErrorPayload? {
        struct Envelope: Decodable { let error: StreamErrorPayload }
        return try? JSONDecoder().decode(Envelope.self, from: Data(body.utf8)).error
    }

    /// `retry-after` в секундах (`"12"`, `"1.5"`) — так его присылает Groq.
    /// Формат HTTP-даты не поддерживаем: Groq его не использует.
    static func retryAfter(_ value: String?) -> Duration? {
        guard let value = value?.trimmingCharacters(in: .whitespaces),
              let seconds = Double(value), seconds.isFinite
        else { return nil }
        return .milliseconds(Int((max(seconds, 0) * 1000).rounded(.up)))
    }

    private static func classify(_ payload: StreamErrorPayload) -> ErrorKind? {
        let fields = [payload.code, payload.type].compactMap { $0?.lowercased() }
        func matches(_ candidates: Set<String>) -> Bool { fields.contains(where: candidates.contains) }

        // У Groq лимиты приходят как code `rate_limit_exceeded`, type `tokens`/`requests`.
        if matches(["rate_limit_exceeded", "rate_limit_error", "tokens", "requests"]) { return .rateLimited }
        if matches(["invalid_api_key", "authentication_error", "unauthorized"]) { return .unauthorized }
        if matches(["permission_denied", "permission_error", "forbidden"]) { return .forbidden }
        if matches(["server_error", "internal_server_error", "service_unavailable", "overloaded_error"]) { return .server }
        return nil
    }
}
