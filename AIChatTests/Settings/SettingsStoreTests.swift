import Foundation
import Testing
@testable import AIChat

@MainActor
struct SettingsStoreTests {
    /// Отдельный набор `UserDefaults` на каждый тест — не трогаем настройки приложения.
    private let suiteName = "SettingsStoreTests.\(UUID().uuidString)"

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: suiteName))
    }

    @Test func defaultsFollowSystemAndKeepNotificationsOff() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsSettingsStore(defaults: defaults)

        #expect(store.appearance == .system)
        #expect(store.notifyOnReply == false)
        #expect(store.notifyOnQueuedSent == false)
    }

    @Test func changesSurviveNewInstance() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.appearance = .dark
        store.notifyOnReply = true
        store.notifyOnQueuedSent = true

        let reloaded = UserDefaultsSettingsStore(defaults: defaults)
        #expect(reloaded.appearance == .dark)
        #expect(reloaded.notifyOnReply == true)
        #expect(reloaded.notifyOnQueuedSent == true)

        reloaded.notifyOnReply = false
        reloaded.appearance = .light
        let again = UserDefaultsSettingsStore(defaults: defaults)
        #expect(again.appearance == .light)
        #expect(again.notifyOnReply == false)
    }

    @Test func unknownStoredAppearanceFallsBackToSystem() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("sepia", forKey: "settings.appearance")

        #expect(UserDefaultsSettingsStore(defaults: defaults).appearance == .system)
    }
}
