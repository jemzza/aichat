import SwiftUI

/// Ответ ассистента в блочном markdown: заголовки, списки, цитаты, разделители
/// и карточки кода. Шрифт (serif) задаёт родитель через `textStyle(.assistantMessage)`.
struct MarkdownView: View {
    let text: String
    var copyCode: (String) -> Void = { _ in }

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            InlineText(text, font: Self.headingFont(level: level))
                .padding(.top, level <= 2 ? 4 : 0)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            InlineText(text)
        case let .list(ordered, items):
            ListBlock(ordered: ordered, items: items)
        case let .code(language, code, _):
            CodeCard(language: language, code: code, copy: copyCode)
        case let .quote(text):
            InlineText(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.4)).frame(width: 3)
                }
        case .thematicBreak:
            Divider().padding(.vertical, 4)
        }
    }

    private static func headingFont(level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.bold()
        }
    }
}

/// Текст блока с инлайн-разметкой (жирный, курсив, `код`, ссылки).
/// Не разобралось — простой текст.
private struct InlineText: View {
    let source: String
    let font: Font

    init(_ source: String, font: Font = .body) {
        self.source = source
        self.font = font
    }

    var body: some View {
        Text(Self.attributed(source, font: font))
            .font(font)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            // Плавное появление новых токенов.
            .contentTransition(.opacity)
    }

    static func attributed(_ source: String, font: Font) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var text = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }
        // `.fontDesign(.serif)` у ответа перебивает стандартный вид `кода` — задаём моноширинный явно.
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            text[run.range].font = font.monospaced()
        }
        return text
    }
}

private struct ListBlock: View {
    let ordered: Bool
    let items: [MarkdownListItem]

    @ScaledMetric(relativeTo: .body) private var indent: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var bulletSize: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(for: item)
                        .frame(minWidth: indent, alignment: .trailing)
                    InlineText(item.text)
                }
                .padding(.leading, CGFloat(item.level) * indent)
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem) -> some View {
        if let number = item.number {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            // Маркер — фигура, а не символ «•»: не тащим служебный знак в String Catalog.
            let size = bulletSize
            Circle()
                .fill(.secondary)
                .frame(width: size, height: size)
                .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.bottom] + size / 2 }
                .accessibilityHidden(true)
        }
    }
}

/// Карточка кода: язык, «Copy», моноширинный текст с горизонтальной прокруткой.
private struct CodeCard: View {
    let language: String?
    let code: String
    let copy: (String) -> Void

    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language {
                    // Язык из ответа модели — содержимое, а не строка интерфейса.
                    Text(language)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copy(code)
                    isCopied = true
                } label: {
                    Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(minHeight: 32)
                .contentShape(.rect)
                .sensoryFeedback(.success, trigger: isCopied) { _, copied in copied }
                .task(id: isCopied) {
                    guard isCopied else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    isCopied = false
                }
            }
            .fontDesign(.default)
            .padding(.horizontal, 12)
            .padding(.top, 4)

            Divider().opacity(0.5)

            ScrollView(.horizontal) {
                // Код — содержимое ответа; markdown внутри не разбираем.
                Text(code)
                    .font(.callout.monospaced())
                    .fontDesign(.monospaced)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .scrollIndicators(.hidden)
        }
        .background(.appSurface, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.2)) }
    }
}

#if DEBUG
private let previewMarkdown = """
    # Actors in Swift

    An **actor** protects its *mutable* state; calls from outside are `await`ed.

    ## Key points
    - only one task touches the state at a time;
    - isolation is checked by the compiler
      - even across modules
    1. Declare the actor.
    2. Call it with `await`.

    > Actors are reference types.

    ---

    ```swift
    actor Counter {
        private var value = 0
        func increment() { value += 1 } // a fairly long line to show horizontal scrolling
    }
    ```

    ```python
    print("streaming, not closed yet")
    """

private struct MarkdownPreview: View {
    var body: some View {
        ScrollView {
            MarkdownView(text: previewMarkdown)
                .textStyle(.assistantMessage)
                .padding()
        }
        .background(.appBackground)
    }
}

#Preview("Light") { MarkdownPreview() }
#Preview("Dark") { MarkdownPreview().preferredColorScheme(.dark) }
#endif
