import Foundation

/// Событие потока OpenAI-совместимого `/chat/completions` со `stream: true`.
enum SSEEvent: Hashable, Sendable {
    /// Очередной кусок текста ответа (непустой).
    case delta(String)
    /// `data: [DONE]` — штатный конец потока.
    case done
    /// `data: {"error": …}` — ошибка пришла внутри потока при HTTP 200.
    case error(StreamErrorPayload)
}

/// Поля ошибки, по которым её можно классифицировать. Текст `message` сознательно
/// не храним: сырой ответ сервера не должен попасть в UI или логи.
struct StreamErrorPayload: Hashable, Sendable, Decodable {
    let type: String?
    let code: String?
}

/// Построчный SSE-парсер. Строки приходят из `URLSession.AsyncBytes.lines`, который
/// уже режет поток по переводам строки и пропускает пустые строки; у Groq одно
/// событие — одна строка `data:`, поэтому собирать многострочные события не нужно.
///
/// Всё, что не похоже на осмысленное событие (комментарии `:`, `event:`/`id:`,
/// пустые `data:`, не-JSON, обрезанный JSON, чанки без текста), возвращает `nil`:
/// мусор в потоке не должен обрывать ответ.
enum SSEParser {
    static func parse(line rawLine: String) -> SSEEvent? {
        var line = Substring(rawLine)
        if line.hasSuffix("\r") { line = line.dropLast() }
        guard line.hasPrefix("data:") else { return nil }

        var payload = line.dropFirst("data:".count)
        // По спецификации SSE после двоеточия убирается ровно один пробел.
        if payload.hasPrefix(" ") { payload = payload.dropFirst() }

        let trimmed = payload.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "[DONE]" { return .done }

        let data = Data(trimmed.utf8)
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
            return .error(envelope.error)
        }
        guard let chunk = try? decoder.decode(Chunk.self, from: data) else { return nil }

        let text = chunk.choices.compactMap(\.delta?.content).joined()
        return text.isEmpty ? nil : .delta(text)
    }

    private struct ErrorEnvelope: Decodable {
        let error: StreamErrorPayload
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            let delta: Delta?
        }

        struct Delta: Decodable {
            let content: String?
        }

        let choices: [Choice]
    }
}
