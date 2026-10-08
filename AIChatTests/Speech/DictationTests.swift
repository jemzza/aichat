import Foundation
import Testing
@testable import AIChat

private struct Boom: Error {}

@MainActor
struct DictationTests {
    private func makeChat(
        transcriber: FakeSpeechTranscriber = FakeSpeechTranscriber(),
        speech: FakeSpeechSynthesizer? = nil,
        session: (any ChatSession)? = nil
    ) -> ChatViewModel {
        let repository = InMemoryChatRepository()
        return ChatViewModel(chatId: nil, repository: repository,
                             session: session ?? PreviewChatSession(repository: repository,
                                                                    connectivity: FakeConnectivityMonitor(isOnline: true)),
                             speech: speech, transcriber: transcriber)
    }

    @Test func joinAddsSingleSpace() {
        #expect(Transcript.join("Hello", "world") == "Hello world")
        #expect(Transcript.join("Hello ", "world") == "Hello world")
        #expect(Transcript.join("", "world") == "world")
        #expect(Transcript(finalized: "One.", volatile: "two").text == "One. two")
    }

    @Test func dictationAppendsToTypedTextAndReplacesVolatile() async throws {
        let transcriber = FakeSpeechTranscriber()
        let chat = makeChat(transcriber: transcriber)
        chat.inputText = "Note:"
        await chat.toggleDictation()
        let dictation = try #require(chat.dictation)
        try await waitUntil { dictation.state == .recording }

        transcriber.send(.transcript(Transcript(volatile: "buy mlk")))
        try await waitUntil { chat.inputText == "Note: buy mlk" }
        transcriber.send(.transcript(Transcript(finalized: "Buy milk.")))
        try await waitUntil { chat.inputText == "Note: Buy milk." }

        await chat.toggleDictation()
        #expect(transcriber.finishCount == 1)
        transcriber.complete(with: "Buy milk.")
        try await waitUntil { dictation.state == .idle }
        #expect(chat.inputText == "Note: Buy milk.")
    }

    @Test func userEditStopsDictationAndKeepsEdit() async throws {
        let transcriber = FakeSpeechTranscriber()
        let chat = makeChat(transcriber: transcriber)
        await chat.toggleDictation()
        let dictation = try #require(chat.dictation)
        transcriber.send(.transcript(Transcript(volatile: "hello")))
        try await waitUntil { chat.inputText == "hello" }

        chat.inputText = "hello there"
        #expect(transcriber.finishCount == 1)
        transcriber.send(.transcript(Transcript(volatile: "hello world")))
        transcriber.complete(with: "hello world")
        try await waitUntil { dictation.state == .idle }
        #expect(chat.inputText == "hello there")
    }

    @Test func deniedMicrophoneShowsSettingsMessage() async throws {
        let chat = makeChat(transcriber: FakeSpeechTranscriber(script: .fail(DictationUnavailability.microphoneDenied)))
        await chat.toggleDictation()
        let dictation = try #require(chat.dictation)
        try await waitUntil { dictation.state == .unavailable(.microphoneDenied) }
        #expect(dictation.canOpenSettings)
        #expect(DictationMessagePresentation(state: dictation.state) != nil)

        dictation.dismissMessage()
        #expect(dictation.state == .idle)
    }

    @Test func otherErrorIsFailureWithoutSettings() async throws {
        let chat = makeChat(transcriber: FakeSpeechTranscriber(script: .fail(Boom())))
        await chat.toggleDictation()
        let dictation = try #require(chat.dictation)
        try await waitUntil { dictation.state == .failed }
        #expect(!dictation.canOpenSettings)
    }

    @Test func downloadProgressIsShown() async throws {
        let transcriber = FakeSpeechTranscriber()
        let chat = makeChat(transcriber: transcriber)
        await chat.toggleDictation()
        let dictation = try #require(chat.dictation)
        transcriber.send(.downloading(fraction: 0.4))
        try await waitUntil { dictation.state == .downloading(0.4) }
        #expect(dictation.isActive)
    }

    @Test func dictationStopsReadingAndBlocksReadAloud() async throws {
        let speech = FakeSpeechSynthesizer()
        let chat = makeChat(speech: speech)
        let reply = Message(chatId: UUID(), role: .assistant, text: "Hi", status: .done, createdAt: .now)
        speech.speak("Hi", messageId: reply.id)

        await chat.toggleDictation()
        #expect(speech.stopCount == 1)
        #expect(!chat.canReadAloud(reply))
    }

    @Test func sendDuringDictationWaitsForFinalTextAndSendsOnce() async throws {
        let transcriber = FakeSpeechTranscriber(script: .phrase("Hello there", wordDelay: .milliseconds(1)))
        let repository = InMemoryChatRepository()
        let session = PreviewChatSession(repository: repository, connectivity: FakeConnectivityMonitor(isOnline: true))
        let chat = ChatViewModel(chatId: nil, repository: repository, session: session, transcriber: transcriber)
        await chat.toggleDictation()
        try await waitUntil { chat.inputText == "Hello there" }

        await chat.send()

        #expect(chat.inputText.isEmpty)
        #expect(chat.dictation?.isActive == false)
        var iterator = repository.observeChats().makeAsyncIterator()
        let chats = await iterator.next()
        #expect(chats?.count == 1)
    }

    @Test func finishTimesOutIfTranscriberNeverEnds() async throws {
        let transcriber = FakeSpeechTranscriber()
        let dictation = DictationViewModel(transcriber: transcriber, finishTimeout: .milliseconds(50))
        dictation.start(prefix: "") { _ in }
        try await waitUntil { dictation.state == .recording }

        await dictation.finish()

        #expect(dictation.state == .idle)
    }
}
