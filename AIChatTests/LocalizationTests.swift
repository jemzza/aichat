import Foundation
import Testing
@testable import AIChat

/// Русская локализация (6.4): каждая строка каталога, которую нужно переводить,
/// есть в собранном `ru.lproj` — новая строка без перевода роняет тест.
struct LocalizationTests {
    private struct Catalog: Decodable {
        struct Entry: Decodable {
            var shouldTranslate: Bool?
        }

        let strings: [String: Entry]
    }

    /// Исходный каталог из репозитория (симулятор и Mac Catalyst читают файлы хоста).
    private func catalog(_ name: String) throws -> Catalog {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "AIChat/Resources/\(name).xcstrings")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    private func russianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "ru", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func everyTranslatableStringHasRussian() throws {
        let russian = try russianBundle()
        let missingMarker = "\u{0}missing"
        let untranslated = try catalog("Localizable").strings
            .filter { $0.value.shouldTranslate != false }
            .map(\.key)
            .filter { russian.localizedString(forKey: $0, value: missingMarker, table: nil) == missingMarker }
        #expect(untranslated.isEmpty, "No Russian for: \(untranslated.sorted())")
    }

    @Test func permissionPromptsAreTranslated() throws {
        let russian = try russianBundle()
        // Название приложения («AI Chat») не переводим — `shouldTranslate: false`.
        for key in try catalog("InfoPlist").strings.filter({ $0.value.shouldTranslate != false }).keys {
            let value = russian.localizedString(forKey: key, value: nil, table: "InfoPlist")
            #expect(value != key)
        }
    }

    @Test func formatsKeepTheirPlaceholders() throws {
        let russian = try russianBundle()
        let format = russian.localizedString(forKey: "Try again in %lld s", value: nil, table: nil)
        #expect(String(format: format, 30) == "Повторить можно через 30 с")
    }

    @Test func queuedNotificationUsesRussianPlurals() throws {
        let russian = try russianBundle()
        let format = russian.localizedString(forKey: "%lld messages waiting for a connection were sent.",
                                             value: nil, table: nil)
        #expect(String(format: format, locale: Locale(identifier: "ru"), 1) == "Отправлено 1 сообщение, ждавшее подключения.")
        #expect(String(format: format, locale: Locale(identifier: "ru"), 3) == "Отправлено 3 сообщения, ждавших подключения.")
        #expect(String(format: format, locale: Locale(identifier: "ru"), 5) == "Отправлено 5 сообщений, ждавших подключения.")
    }
}
