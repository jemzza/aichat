import Foundation
import Testing
@testable import AIChat

private struct Boom: Error {}

@MainActor
struct DictationTests {
    private func makeChat(
        recorder: FakeVoiceRecorder = FakeVoiceRecorder(ticks: false),
        transcriber: FakeSpeechTranscriber = FakeSpeechTranscriber(result: .success("Hello world.")),
        speech: FakeSpeechSynthesizer? = nil
    ) -> ChatViewModel {
        let repository = InMemoryChatRepository()
        return ChatViewModel(chatId: nil, repository: repository,
                             session: PreviewChatSession(repository: repository,
                                                         connectivity: FakeConnectivityMonitor(isOnline: true)),
                             speech: speech, recorder: recorder, transcriber: transcriber)
    }

    /// Зажать микрофон и «наговорить» `duration`.
    private func record(_ chat: ChatViewModel, recorder: FakeVoiceRecorder, duration: Duration = .seconds(2)) async throws {
        chat.beginDictation()
        let dictation = try #require(chat.dictation)
        try await waitUntil { dictation.state == .recording }
        recorder.send(.progress(duration: duration, level: 0.5))
        try await waitUntil { dictation.duration == duration }
    }

    @Test func joinAddsSingleSpace() {
        #expect(DictationText.join("Hello", "world") == "Hello world")
        #expect(DictationText.join("Hello ", "world") == "Hello world")
        #expect(DictationText.join("", "world") == "world")
    }

    @Test func releaseTranscribesAppendsAndDiscardsFile() async throws {
        let recorder = FakeVoiceRecorder(ticks: false)
        let transcriber = FakeSpeechTranscriber(result: .success("Buy milk."))
        let chat = makeChat(recorder: recorder, transcriber: transcriber)
        chat.inputText = "Note:"
        try await record(chat, recorder: recorder)

        await chat.endDictation()

        #expect(chat.inputText == "Note: Buy milk.")
        #expect(chat.dictation?.state == .idle)
        #expect(transcriber.transcribedFiles.count == 1)
        #expect(recorder.discarded == transcriber.transcribedFiles)
    }

    @Test func textTypedDuringTranscriptionIsKept() async throws {
        let recorder = FakeVoiceRecorder(ticks: false)
        let transcriber = FakeSpeechTranscriber(result: .success("world"), delay: .milliseconds(100))
        let chat = makeChat(recorder: recorder, transcriber: transcriber)
        try await record(chat, recorder: recorder)

        let release = Task { await chat.endDictation() }
        try await waitUntil { chat.dictation?.state == .transcribing }
        chat.inputText = "Hello"
        await release.value

        #expect(chat.inputText == "Hello world")
    }

    @Test func shortPressShowsHoldHintAndSkipsTranscription() async throws {
        let recorder = FakeVoiceRecorder(ticks: false)
        let transcriber = FakeSpeechTranscriber(result: .success("x"))
        let chat = makeChat(recorder: recorder, transcriber: transcriber)
        try await record(chat, recorder: recorder, duration: .milliseconds(200))

        await chat.endDictation()

        #expect(chat.dictation?.state == .holdHint)
        #expect(recorder.cancelCount == 1)
        #expect(transcriber.transcribedFiles.isEmpty)
        #expect(chat.inputText.isEmpty)
    }

    @Test func releaseBeforeRecordingStartsShowsHoldHint() async throws {
        let recorder = FakeVoiceRecorder(ticks: false)
        let chat = makeChat(recorder: recorder)
        chat.beginDictation()
        // Отпускаем сразу, пока идут запросы разрешений.
        await chat.endDictation()

        #expect(chat.dictation?.state == .holdHint)
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.startCount == 0)
    }

    @Test func autoStopTranscribesWhatWasRecorded() async throws {
        let recorder = FakeVoiceRecorder(ticks: false)
        let chat = makeChat(recorder: recorder)
        try await record(chat, recorder: recorder)

        recorder.send(.stoppedAutomatically)

        try await waitUntil { chat.inputText == "Hello world." }
        #expect(chat.dictation?.state == .idle)
    }

    @Test func emptyResultSaysNothingHeard() async throws {
        let recorder = FakeVoiceRecorder(ticks: false)
        let chat = makeChat(recorder: recorder, transcriber: FakeSpeechTranscriber(result: .success("  ")))
        try await record(chat, recorder: recorder)

        await chat.endDictation()

        #expect(chat.dictation?.state == .nothingHeard)
        #expect(chat.inputText.isEmpty)
        #expect(recorder.discarded.count == 1)
    }

    @Test func transcriptionErrorsMapToMessagesAndDiscardFile() async throws {
        for (error, expected) in [
            (DictationUnavailability.dictationDisabled as Error, DictationViewModel.State.unavailable(.dictationDisabled)),
            (Boom(), .failed),
        ] {
            let recorder = FakeVoiceRecorder(ticks: false)
            let chat = makeChat(recorder: recorder, transcriber: FakeSpeechTranscriber(result: .failure(error)))
            try await record(chat, recorder: recorder)

            await chat.endDictation()

            #expect(chat.dictation?.state == expected)
            #expect(recorder.discarded.count == 1)
        }
    }

    @Test func deniedMicrophoneShowsSettingsMessage() async throws {
        let recorder = FakeVoiceRecorder(ticks: false)
        recorder.isPermissionGranted = false
        let chat = makeChat(recorder: recorder)
        chat.beginDictation()
        let dictation = try #require(chat.dictation)

        try await waitUntil { dictation.state == .unavailable(.microphoneDenied) }
        #expect(dictation.canOpenSettings)
        #expect(recorder.startCount == 0)
        dictation.dismissMessage()
        #expect(dictation.state == .idle)
    }

    @Test func deniedRecognitionIsAskedBeforeRecording() async throws {
        let recorder = FakeVoiceRecorder(ticks: false)
        let transcriber = FakeSpeechTranscriber()
        transcriber.prepareError = DictationUnavailability.recognitionDenied
        let chat = makeChat(recorder: recorder, transcriber: transcriber)
        chat.beginDictation()

        try await waitUntil { chat.dictation?.state == .unavailable(.recognitionDenied) }
        #expect(recorder.startCount == 0)
    }

    @Test func downloadProgressThenTranscribing() async throws {
        let recorder = FakeVoiceRecorder(ticks: false)
        let transcriber = FakeSpeechTranscriber(result: .success("Hi"), delay: .milliseconds(200))
        transcriber.downloadSteps = [0.4]
        let chat = makeChat(recorder: recorder, transcriber: transcriber)
        try await record(chat, recorder: recorder)

        let release = Task { await chat.endDictation() }
        try await waitUntil { chat.dictation?.state == .downloading(0.4) }
        await release.value
        #expect(chat.inputText == "Hi")
    }

    @Test func secondPressWhileRecordingDoesNotRestart() async throws {
        let recorder = FakeVoiceRecorder(ticks: false)
        let chat = makeChat(recorder: recorder)
        try await record(chat, recorder: recorder)
        chat.beginDictation()
        #expect(recorder.startCount == 1)
    }

    @Test func voiceOverToggleStartsAndStops() async throws {
        let recorder = FakeVoiceRecorder(ticks: false)
        let chat = makeChat(recorder: recorder)
        await chat.toggleDictation()
        try await waitUntil { chat.dictation?.state == .recording }
        recorder.send(.progress(duration: .seconds(1), level: 0.5))
        try await waitUntil { chat.dictation?.duration == .seconds(1) }

        await chat.toggleDictation()

        #expect(chat.inputText == "Hello world.")
    }

    @Test func dictationStopsReadingAndBlocksReadAloud() async throws {
        let speech = FakeSpeechSynthesizer()
        let chat = makeChat(speech: speech)
        let reply = Message(chatId: UUID(), role: .assistant, text: "Hi", status: .done, createdAt: .now)
        speech.speak("Hi", messageId: reply.id)

        chat.beginDictation()

        #expect(speech.stopCount == 1)
        #expect(!chat.canReadAloud(reply))
    }

    @Test func sendDuringRecordingWaitsForTranscriptionAndSendsOnce() async throws {
        let recorder = FakeVoiceRecorder(ticks: false)
        let repository = InMemoryChatRepository()
        let session = PreviewChatSession(repository: repository, connectivity: FakeConnectivityMonitor(isOnline: true))
        let chat = ChatViewModel(chatId: nil, repository: repository, session: session,
                                 recorder: recorder, transcriber: FakeSpeechTranscriber(result: .success("Hello there")))
        try await record(chat, recorder: recorder)

        await chat.send()

        #expect(chat.inputText.isEmpty)
        #expect(chat.dictation?.isActive == false)
        var iterator = repository.observeChats().makeAsyncIterator()
        let chats = await iterator.next()
        #expect(chats?.count == 1)
    }

    @Test func cancelDropsRecording() async throws {
        let recorder = FakeVoiceRecorder(ticks: false)
        let chat = makeChat(recorder: recorder)
        try await record(chat, recorder: recorder)

        chat.stopDictation()

        #expect(recorder.cancelCount == 1)
        #expect(chat.dictation?.state == .idle)
        #expect(chat.inputText.isEmpty)
    }

    @Test func everyFailureHasMessage() {
        let reasons: [DictationUnavailability] = [
            .microphoneDenied, .recognitionDenied, .languageNotSupported, .needsDownload, .serviceUnavailable,
            .dictationDisabled,
        ]
        for reason in reasons {
            #expect(DictationMessagePresentation(state: .unavailable(reason)) != nil)
        }
        for state in [DictationViewModel.State.failed, .holdHint, .nothingHeard] {
            #expect(DictationMessagePresentation(state: state) != nil)
        }
    }
}
