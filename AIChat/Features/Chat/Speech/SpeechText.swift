import Foundation

/// Текст ответа для озвучки: Markdown → простые фразы. Блоки кода не читаются,
/// заголовки и пункты списков — отдельные фразы, у ссылок — только текст.
enum SpeechText {
    static func make(fromMarkdown markdown: String) -> String {
        MarkdownParser.parse(markdown)
            .flatMap(sentences)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func sentences(_ block: MarkdownBlock) -> [String] {
        switch block {
        case let .heading(_, text):
            [sentence(plain(text))]
        case let .paragraph(text), let .quote(text):
            [plain(withoutTables(text))]
        case let .list(_, items):
            items.map { sentence(plain($0.text)) }
        case .code, .thematicBreak:
            []
        }
    }

    /// Инлайн-разметка (жирный, курсив, `код`, ссылки) → только видимый текст.
    private static func plain(_ source: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let text = (try? AttributedString(markdown: source, options: options))
            .map { String($0.characters) } ?? source
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Таблицы парсер оставляет абзацами: строку-разделитель пропускаем, ячейки читаем через запятую.
    private static func withoutTables(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("|") else { return String(line) }
                if trimmed.allSatisfy({ "|-: ".contains($0) }) { return nil }
                let cells = trimmed.split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return sentence(cells.joined(separator: ", "))
            }
            .joined(separator: "\n")
    }

    /// Пауза между фразами: без знака в конце синтезатор склеивает заголовок со следующим текстом.
    private static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?…:;".contains(last) else { return text }
        return text + "."
    }
}
