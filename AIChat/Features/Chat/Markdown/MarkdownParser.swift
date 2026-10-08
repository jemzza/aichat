import Foundation

/// Блок markdown-ответа. Инлайн-разметка (жирный, курсив, `код`, ссылки) остаётся
/// в тексте блока — её разбирает `AttributedString` при отрисовке.
enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, items: [MarkdownListItem])
    /// `isClosed == false` — закрывающих ``` ещё нет (ответ стримится): рисуем как открытый.
    case code(language: String?, code: String, isClosed: Bool)
    case quote(String)
    case thematicBreak
}

struct MarkdownListItem: Hashable, Sendable {
    /// Номер для нумерованного списка, `nil` — маркер.
    let number: Int?
    /// Уровень вложенности: 0 — верхний.
    let level: Int
    let text: String
}

/// Простой построчный парсер блочного markdown (заголовки, списки, код, цитаты,
/// разделители, абзацы) — то, что реально присылает модель. Таблицы и прочее
/// остаются абзацами. Никогда не падает: на любом входе отдаёт блоки.
enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var parser = State()
        // `isNewline`, а не "\n": в Swift "\r\n" — один `Character`.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            parser.consume(String(line))
        }
        return parser.finish()
    }

    private struct State {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var listItems: [MarkdownListItem] = []
        var listIsOrdered = false
        /// Открытый блок кода: забор (```/~~~), язык, строки.
        var fence: (marker: String, language: String?, lines: [String])?

        mutating func consume(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if var open = fence {
                // Закрывает строка только из того же символа, не короче открывающего забора.
                if let markerCharacter = open.marker.first, trimmed.count >= open.marker.count,
                   trimmed.allSatisfy({ $0 == markerCharacter }) {
                    blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n"), isClosed: true))
                    fence = nil
                } else {
                    open.lines.append(line)
                    fence = open
                }
                return
            }

            if let marker = Self.fenceMarker(trimmed) {
                flushAll()
                let language = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                fence = (marker, language.isEmpty ? nil : language, [])
                return
            }

            if trimmed.isEmpty {
                flushAll()
                return
            }

            if let heading = Self.heading(trimmed) {
                flushAll()
                blocks.append(heading)
                return
            }

            if Self.isThematicBreak(trimmed) {
                flushAll()
                blocks.append(.thematicBreak)
                return
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                return
            }
            flushQuote()

            if let (item, ordered) = Self.listItem(line) {
                flushParagraph()
                if !listItems.isEmpty, ordered != listIsOrdered, item.level == 0 { flushList() }
                if listItems.isEmpty { listIsOrdered = ordered }
                listItems.append(item)
                return
            }

            // Строка с отступом сразу после пункта — продолжение этого пункта.
            if let last = listItems.last, paragraph.isEmpty, line.hasPrefix("  ") {
                listItems[listItems.count - 1] = MarkdownListItem(number: last.number, level: last.level,
                                                                 text: last.text + "\n" + trimmed)
                return
            }
            flushList()
            paragraph.append(trimmed)
        }

        mutating func finish() -> [MarkdownBlock] {
            if let open = fence {
                blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n"), isClosed: false))
                fence = nil
            }
            flushAll()
            return blocks
        }

        private mutating func flushAll() {
            flushParagraph()
            flushQuote()
            flushList()
        }

        private mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        private mutating func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote = []
        }

        private mutating func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(ordered: listIsOrdered, items: listItems))
            listItems = []
        }

        // MARK: Распознавание строк

        private static func fenceMarker(_ trimmed: String) -> String? {
            for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
                // Забор — 3+ одинаковых символа; берём ровно столько, сколько их подряд.
                let count = trimmed.prefix { $0 == marker.first }.count
                return String(repeating: String(marker.prefix(1)), count: count)
            }
            return nil
        }

        private static func heading(_ trimmed: String) -> MarkdownBlock? {
            let hashes = trimmed.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes) else { return nil }
            let rest = trimmed.dropFirst(hashes)
            guard rest.isEmpty || rest.first == " " else { return nil }
            var text = rest.trimmingCharacters(in: .whitespaces)
            // Закрывающие решётки: «## Title ##».
            while text.hasSuffix("#") { text.removeLast() }
            return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
        }

        private static func isThematicBreak(_ trimmed: String) -> Bool {
            let compact = trimmed.filter { $0 != " " }
            guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
            return compact.allSatisfy { $0 == first }
        }

        private static func listItem(_ line: String) -> (MarkdownListItem, ordered: Bool)? {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let body = line.drop { $0 == " " || $0 == "\t" }
            let level = indent / 2

            if let marker = body.first, "-*+".contains(marker), body.dropFirst().first == " " {
                let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return (MarkdownListItem(number: nil, level: level, text: text), false)
            }

            let digits = body.prefix { $0.isNumber }
            guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
            let afterDigits = body.dropFirst(digits.count)
            guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
                  afterDigits.dropFirst().first == " " else { return nil }
            let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return (MarkdownListItem(number: number, level: level, text: text), true)
        }
    }
}
