import Foundation

/// Запрос к модели на устройстве: у `LanguageModelSession` — инструкции и один промпт,
/// поэтому история переписки складывается в текст промпта. Без Foundation Models —
/// чтобы проверялось тестами и на iOS 18.
struct OnDevicePrompt: Hashable, Sendable {
    /// Тот же смысл, что у системного промпта Groq.
    static let defaultInstructions = "Answer in the language of the user's last message. Be concise."

    let instructions: String
    let prompt: String

    /// - Parameter messages: история от `ChatService` (уже отфильтрована и обрезана),
    ///   последнее сообщение — вопрос пользователя.
    init(messages: [LLMMessage]) {
        let system = messages.filter { $0.role == .system }.map(\.content)
        instructions = system.isEmpty ? Self.defaultInstructions : system.joined(separator: "\n\n")

        var turns = messages.filter { $0.role != .system }
        guard let last = turns.popLast() else {
            prompt = ""
            return
        }
        guard !turns.isEmpty else {
            prompt = last.content
            return
        }
        // Служебная разметка для модели, а не строки интерфейса.
        let transcript = turns.map { turn in
            "\(turn.role == .user ? "User" : "Assistant"): \(turn.content)"
        }.joined(separator: "\n\n")
        prompt = """
            Conversation so far:

            \(transcript)

            Reply to the user's last message:

            \(last.content)
            """
    }

    /// Модель отдаёт накопленный текст целиком, `LLMProvider` — дельты.
    /// - Returns: новый хвост; `nil`, если снимок не продолжает уже отданный текст.
    static func delta(from emitted: String, to snapshot: String) -> String? {
        guard snapshot.hasPrefix(emitted) else { return nil }
        let tail = String(snapshot.dropFirst(emitted.count))
        return tail.isEmpty ? nil : tail
    }
}
