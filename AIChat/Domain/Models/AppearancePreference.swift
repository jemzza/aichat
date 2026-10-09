import Foundation

/// Тема приложения из настроек. `system` — как в системе.
enum AppearancePreference: String, CaseIterable, Sendable, Hashable {
    case light
    case dark
    case system
}
