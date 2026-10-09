import Foundation
import Observation

/// `SettingsStoring` поверх `UserDefaults`. Значения по умолчанию: тема как в системе,
/// уведомления выключены — разрешение запрашиваем только при первом включении.
@MainActor
@Observable
final class UserDefaultsSettingsStore: SettingsStoring {
    private enum Key {
        static let appearance = "settings.appearance"
        static let notifyOnReply = "settings.notifyOnReply"
        static let notifyOnQueuedSent = "settings.notifyOnQueuedSent"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var notifyOnReply: Bool {
        didSet { defaults.set(notifyOnReply, forKey: Key.notifyOnReply) }
    }

    var notifyOnQueuedSent: Bool {
        didSet { defaults.set(notifyOnQueuedSent, forKey: Key.notifyOnQueuedSent) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppearancePreference.init) ?? .system
        notifyOnReply = defaults.bool(forKey: Key.notifyOnReply)
        notifyOnQueuedSent = defaults.bool(forKey: Key.notifyOnQueuedSent)
    }
}
