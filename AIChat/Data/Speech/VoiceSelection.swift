import Foundation
import NaturalLanguage

/// Голос синтезатора как значение — чтобы выбор тестировался без `AVSpeechSynthesisVoice`.
struct VoiceInfo: Hashable, Sendable {
    enum Quality: Int, Comparable, Sendable {
        case standard, enhanced, premium

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let identifier: String
    /// BCP 47, как у `AVSpeechSynthesisVoice.language`: `ru-RU`, `en-US`.
    let language: String
    let quality: Quality
}

/// Выбор голоса для текста: язык определяется по самому тексту (ответ может быть
/// не на языке системы), регион и качество — по предпочтениям пользователя.
enum VoiceSelection {
    /// Язык текста (`ru`, `en`); `nil` — не удалось определить уверенно.
    static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

    /// - Returns: голос на языке текста (или языке пользователя, если язык не определился):
    ///   сначала с регионом пользователя, затем лучшего качества. `nil` — подходящего нет,
    ///   синтезатор возьмёт голос по умолчанию.
    static func voice(for text: String, among voices: [VoiceInfo], userLocale: Locale) -> VoiceInfo? {
        guard let language = language(of: text) ?? userLocale.language.languageCode?.identifier else {
            return nil
        }
        let userRegion = userLocale.region?.identifier
        let candidates = voices.filter { languageCode(of: $0.language) == base(language) }
        return candidates.max { lhs, rhs in
            let lhsRegion = region(of: lhs.language) == userRegion
            let rhsRegion = region(of: rhs.language) == userRegion
            if lhsRegion != rhsRegion { return !lhsRegion }
            return lhs.quality < rhs.quality
        }
    }

    /// `zh-Hans` → `zh`: у голосов язык без письменности.
    private static func base(_ language: String) -> String {
        languageCode(of: language)
    }

    private static func languageCode(of identifier: String) -> String {
        Locale.Language(identifier: identifier).languageCode?.identifier ?? identifier
    }

    private static func region(of identifier: String) -> String? {
        Locale.Language(identifier: identifier).region?.identifier
    }
}
