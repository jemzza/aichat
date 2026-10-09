import SwiftUI
import UIKit

extension AppearancePreference {
    /// System — `.unspecified`: окно следует системе.
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: .unspecified
        }
    }
}

/// Тема из настроек — стилем окон сцены, а не `.preferredColorScheme` (см. docs/task.md):
/// так она сразу действует и на sheet, и на алерты, а System честно возвращает системную.
private struct WindowAppearance: ViewModifier {
    let appearance: AppearancePreference

    func body(content: Content) -> some View {
        content
            .onAppear { apply() }
            .onChange(of: appearance) { apply() }
    }

    private func apply() {
        let style = appearance.interfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

extension View {
    func windowAppearance(_ appearance: AppearancePreference) -> some View {
        modifier(WindowAppearance(appearance: appearance))
    }
}
