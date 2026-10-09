import Foundation

/// Параметры доступа к Groq. Ключ никогда не попадает в `description`/`debugDescription`,
/// поэтому случайный `print(configuration)` или дамп в отладчике его не покажет.
struct GroqConfiguration: Sendable, Equatable {
    static let defaultModel = "openai/gpt-oss-120b"
    /// Единственная vision-модель Groq (preview, 2026-10-08): запросы с фото идут в неё.
    static let defaultVisionModel = "qwen/qwen3.8-27b"

    let apiKey: String
    let model: String
    var visionModel = GroqConfiguration.defaultVisionModel

    var hasAPIKey: Bool { !apiKey.isEmpty }

    /// Ключ из обфусцированного `Secrets.generated.swift` (см. `scripts/gen_secrets.py`).
    static func bundled() -> GroqConfiguration {
        GroqConfiguration(apiKey: Secrets.groqAPIKey, model: defaultModel)
    }
}

extension GroqConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "GroqConfiguration(model: \(model), apiKey: \(hasAPIKey ? "<redacted>" : "<missing>"))"
    }

    var debugDescription: String { description }
}
