import Testing
@testable import AIChat

/// Проверяем только форму ключа, не сам ключ.
/// Значения сначала сводятся к `Bool`: если передать строку в `#expect`, Swift Testing
/// при падении напечатает её содержимое — то есть ключ — в лог.
struct SecretsTests {
    @Test func bundledKeyHasGroqPrefix() {
        let hasPrefix = Secrets.groqAPIKey.hasPrefix("gsk_")
        #expect(hasPrefix, "Key must start with the Groq prefix")
    }

    @Test func bundledKeyIsNotEmpty() {
        let isEmpty = Secrets.groqAPIKey.isEmpty
        #expect(!isEmpty, "Key must not be empty")
    }

    @Test func bundledConfigurationUsesKey() {
        let hasKey = GroqConfiguration.bundled().hasAPIKey
        #expect(hasKey)
    }

    @Test func descriptionRedactsKey() {
        let configuration = GroqConfiguration(apiKey: "gsk_synthetic_test_value", model: "m")
        let leaks = String(describing: configuration).contains("synthetic")
            || String(reflecting: configuration).contains("synthetic")
        #expect(!leaks)
    }
}
