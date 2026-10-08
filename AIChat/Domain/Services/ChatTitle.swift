import Foundation

/// Автозаголовок чата — обрезка первого сообщения, без запроса к LLM (экономия лимита).
enum ChatTitle {
    static func make(from text: String) -> String {
        String(text.prefix(40))
    }
}
