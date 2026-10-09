import UIKit

/// Активно ли приложение — по `UIApplication.applicationState`.
@MainActor
final class UIKitAppActivity: AppActivityProviding {
    var isAppActive: Bool {
        UIApplication.shared.applicationState == .active
    }
}
