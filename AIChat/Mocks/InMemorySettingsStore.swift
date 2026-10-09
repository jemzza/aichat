#if DEBUG
import Foundation
import Observation

/// Настройки в памяти — для превью и тестов.
@MainActor
@Observable
final class InMemorySettingsStore: SettingsStoring {
    var appearance: AppearancePreference
    var notifyOnReply: Bool
    var notifyOnQueuedSent: Bool

    init(appearance: AppearancePreference = .system, notifyOnReply: Bool = false, notifyOnQueuedSent: Bool = false) {
        self.appearance = appearance
        self.notifyOnReply = notifyOnReply
        self.notifyOnQueuedSent = notifyOnQueuedSent
    }
}
#endif
