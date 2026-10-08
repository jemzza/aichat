import Testing
@testable import AIChat

struct ChatTitleTests {
    @Test func photoWithoutTextGetsPhotoTitle() {
        #expect(ChatTitle.make(from: " \n ") == "Photo")
    }

    @Test func shortTextIsKeptAsIs() {
        #expect(ChatTitle.make(from: "Plan a weekend in Lisbon") == "Plan a weekend in Lisbon")
    }

    @Test func whitespaceAndNewlinesCollapse() {
        #expect(ChatTitle.make(from: "  Hello\n\n  world\t!  ") == "Hello world !")
    }

    @Test func longTextIsCutAtWordBoundary() {
        let title = ChatTitle.make(from: "Explain how the internet works in simple terms please")
        #expect(title == "Explain how the internet works in…")
        #expect(title.count <= ChatTitle.maxLength)
    }

    @Test func longWordIsCutInTheMiddle() {
        let title = ChatTitle.make(from: String(repeating: "a", count: 60))
        #expect(title == String(repeating: "a", count: 39) + "…")
    }

    @Test func exactlyMaxLengthIsNotCut() {
        let text = String(repeating: "b", count: ChatTitle.maxLength)
        #expect(ChatTitle.make(from: text) == text)
    }

    @Test func emojiAndCyrillicCountAsCharacters() {
        let text = String(repeating: "Привет 👋 ", count: 6)
        let title = ChatTitle.make(from: text)
        #expect(title.count <= ChatTitle.maxLength)
        #expect(title.hasSuffix("…"))
    }
}
