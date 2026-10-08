import Testing
@testable import AIChat

struct MarkdownParserTests {
    @Test func emptyAndBlankInputGiveNoBlocks() {
        #expect(MarkdownParser.parse("").isEmpty)
        #expect(MarkdownParser.parse("\n  \n").isEmpty)
    }

    @Test func paragraphsSplitByBlankLinesKeepLineBreaks() {
        let blocks = MarkdownParser.parse("First line\nsecond **line**\n\nNext paragraph")
        #expect(blocks == [.paragraph("First line\nsecond **line**"), .paragraph("Next paragraph")])
    }

    @Test(arguments: [
        ("# Title", MarkdownBlock.heading(level: 1, text: "Title")),
        ("### Deep `code`", .heading(level: 3, text: "Deep `code`")),
        ("## Closed ##", .heading(level: 2, text: "Closed")),
        ("#hashtag", .paragraph("#hashtag")),
        ("####### Seven", .paragraph("####### Seven")),
    ])
    func headings(input: String, expected: MarkdownBlock) {
        #expect(MarkdownParser.parse(input) == [expected])
    }

    @Test func bulletListWithNestingAndContinuation() {
        let blocks = MarkdownParser.parse("""
            - one
            * two
              continued
              - nested
            + three
            """)
        #expect(blocks == [.list(ordered: false, items: [
            MarkdownListItem(number: nil, level: 0, text: "one"),
            MarkdownListItem(number: nil, level: 0, text: "two\ncontinued"),
            MarkdownListItem(number: nil, level: 1, text: "nested"),
            MarkdownListItem(number: nil, level: 0, text: "three"),
        ])])
    }

    @Test func orderedListKeepsNumbers() {
        let blocks = MarkdownParser.parse("3. three\n4) four")
        #expect(blocks == [.list(ordered: true, items: [
            MarkdownListItem(number: 3, level: 0, text: "three"),
            MarkdownListItem(number: 4, level: 0, text: "four"),
        ])])
    }

    @Test func switchingListKindStartsNewList() {
        let blocks = MarkdownParser.parse("- dot\n1. number")
        #expect(blocks.count == 2)
        #expect(blocks.first == .list(ordered: false, items: [MarkdownListItem(number: nil, level: 0, text: "dot")]))
    }

    @Test func notListItems() {
        #expect(MarkdownParser.parse("-not a list") == [.paragraph("-not a list")])
        #expect(MarkdownParser.parse("2024. was a year") == [.list(ordered: true, items: [
            MarkdownListItem(number: 2024, level: 0, text: "was a year"),
        ])])
        #expect(MarkdownParser.parse("3.14 is pi") == [.paragraph("3.14 is pi")])
    }

    @Test func paragraphAfterListIsSeparate() {
        let blocks = MarkdownParser.parse("- item\nNot indented")
        #expect(blocks == [
            .list(ordered: false, items: [MarkdownListItem(number: nil, level: 0, text: "item")]),
            .paragraph("Not indented"),
        ])
    }

    @Test func closedCodeBlockKeepsContentVerbatim() {
        let blocks = MarkdownParser.parse("""
            Before
            ```swift
            let x = 1

            # not a heading
            - not a list
            ```
            After
            """)
        #expect(blocks == [
            .paragraph("Before"),
            .code(language: "swift", code: "let x = 1\n\n# not a heading\n- not a list", isClosed: true),
            .paragraph("After"),
        ])
    }

    /// Во время стриминга закрывающего забора ещё нет — блок открыт, но код виден.
    @Test func unclosedCodeBlockWhileStreaming() {
        let blocks = MarkdownParser.parse("Here:\n```python\nprint(1)\n    x = 2")
        #expect(blocks == [
            .paragraph("Here:"),
            .code(language: "python", code: "print(1)\n    x = 2", isClosed: false),
        ])
        #expect(MarkdownParser.parse("```") == [.code(language: nil, code: "", isClosed: false)])
    }

    @Test func tildeFenceAndLongerClosingFence() {
        #expect(MarkdownParser.parse("~~~\na\n~~~") == [.code(language: nil, code: "a", isClosed: true)])
        // ``` внутри блока из четырёх обратных кавычек — это содержимое, а не конец.
        #expect(MarkdownParser.parse("````\n```\n````") == [.code(language: nil, code: "```", isClosed: true)])
    }

    @Test func quoteAndThematicBreak() {
        let blocks = MarkdownParser.parse("> quoted\n> more\n\n---\n* * *\ntext")
        #expect(blocks == [.quote("quoted\nmore"), .thematicBreak, .thematicBreak, .paragraph("text")])
    }

    @Test func windowsLineEndings() {
        #expect(MarkdownParser.parse("# T\r\nbody\r\n") == [.heading(level: 1, text: "T"), .paragraph("body")])
    }
}
