import Testing
@testable import AIChat

struct SpeechTextTests {
    @Test func codeBlocksAreNotRead() {
        let markdown = """
            Run this:

            ```swift
            let answer = 42
            ```

            Done.
            """
        #expect(SpeechText.make(fromMarkdown: markdown) == "Run this:\nDone.")
    }

    @Test func unclosedCodeBlockIsNotRead() {
        #expect(SpeechText.make(fromMarkdown: "Look:\n```\nprint(1)") == "Look:")
    }

    @Test func codeOnlyReplyHasNothingToRead() {
        #expect(SpeechText.make(fromMarkdown: "```\nprint(1)\n```").isEmpty)
    }

    @Test func headingsAndListItemsBecomeSentences() {
        let markdown = """
            ## Steps
            - First step
            - Second step!
            1. Numbered
            """
        #expect(SpeechText.make(fromMarkdown: markdown) == "Steps.\nFirst step.\nSecond step!\nNumbered.")
    }

    @Test func inlineMarkupIsRemoved() {
        let markdown = "This is **bold**, *italic*, `code` and a [link](https://example.com)."
        #expect(SpeechText.make(fromMarkdown: markdown) == "This is bold, italic, code and a link.")
    }

    @Test func quotesAreReadAndBreaksSkipped() {
        #expect(SpeechText.make(fromMarkdown: "> Quoted\n\n---\n\nAfter") == "Quoted\nAfter")
    }

    @Test func tableSeparatorIsSkippedAndCellsAreRead() {
        let markdown = """
            | Name | Age |
            |------|----:|
            | Ann | 30 |
            """
        #expect(SpeechText.make(fromMarkdown: markdown) == "Name, Age.\nAnn, 30.")
    }
}
