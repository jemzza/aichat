import Foundation

/// Автозаголовок чата — обрезка первого сообщения, без запроса к LLM (экономия лимита).
enum ChatTitle {
    static let maxLength = 40

    /// Пробелы и переводы строк схлопываются; длинный текст режется по границе слова
    /// (если слово не слишком длинное) и получает «…».
    static func make(from text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let line = words.joined(separator: " ")
        guard line.count > maxLength else { return line }

        let head = line.prefix(maxLength - 1)
        // Режем по последнему пробелу, если он не слишком близко к началу.
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= maxLength / 2 {
            return head[..<space] + "…"
        }
        return head + "…"
    }
}
