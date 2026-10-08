import Testing
@testable import AIChat

struct OnDevicePromptTests {
    @Test func singleQuestionIsThePromptItself() {
        let request = OnDevicePrompt(messages: [LLMMessage(role: .user, content: "Hi")])
        #expect(request.prompt == "Hi")
        #expect(request.instructions == OnDevicePrompt.defaultInstructions)
    }

    @Test func historyGoesIntoPromptAndSystemIntoInstructions() {
        let request = OnDevicePrompt(messages: [
            LLMMessage(role: .system, content: "Be brief."),
            LLMMessage(role: .user, content: "Hi"),
            LLMMessage(role: .assistant, content: "Hello!"),
            LLMMessage(role: .user, content: "How are you?"),
        ])
        #expect(request.instructions == "Be brief.")
        #expect(request.prompt.contains("User: Hi\n\nAssistant: Hello!"))
        #expect(request.prompt.hasSuffix("How are you?"))
        #expect(!request.prompt.contains("User: How are you?"))
    }

    @Test func snapshotsBecomeDeltas() {
        #expect(OnDevicePrompt.delta(from: "", to: "Hel") == "Hel")
        #expect(OnDevicePrompt.delta(from: "Hel", to: "Hello") == "lo")
        #expect(OnDevicePrompt.delta(from: "Hello", to: "Hello") == nil)
        #expect(OnDevicePrompt.delta(from: "Hello", to: "Help") == nil)
    }
}
