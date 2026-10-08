import SwiftUI

// Дизайн-основа (UI-референс в docs/task.md): цвета только из Assets.xcassets
// (у каждого есть Light и Dark) и системные; шрифты системные с Dynamic Type.

extension ShapeStyle where Self == Color {
    /// Тёплый «бумажный» фон экранов.
    static var appBackground: Color { Color(.background) }
    /// Пузырь пользователя, карточки, поле поиска.
    static var appSurface: Color { Color(.surface) }
    /// Акцент: кнопка отправки, выделение.
    static var appAccent: Color { Color(.accent) }
}

/// Стили текста. Ответы ассистента — с засечками (New York), остальное — SF Pro.
enum TextStyle {
    case assistantMessage
    case userMessage
    case chatTitle
    case caption

    var font: Font {
        switch self {
        case .assistantMessage, .userMessage: .body
        case .chatTitle: .headline
        case .caption: .caption
        }
    }

    var design: Font.Design {
        switch self {
        case .assistantMessage: .serif
        case .userMessage, .chatTitle, .caption: .default
        }
    }
}

extension View {
    func textStyle(_ style: TextStyle) -> some View {
        font(style.font).fontDesign(style.design)
    }
}

#if DEBUG
private struct ThemeSwatches: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                swatch(.appBackground, title: "Background")
                swatch(.appSurface, title: "Surface")
                swatch(.appAccent, title: "Accent")
            }
            Text("Assistant replies are set in a serif typeface.")
                .textStyle(.assistantMessage)
            Text("Everything else uses the system font.")
                .textStyle(.userMessage)
            Text("Chat title").textStyle(.chatTitle)
            Text("Caption").textStyle(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.appBackground)
    }

    private func swatch(_ color: Color, title: LocalizedStringKey) -> some View {
        VStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(color)
                .strokeBorder(.secondary.opacity(0.3))
                .frame(width: 64, height: 64)
            Text(title).textStyle(.caption)
        }
    }
}

#Preview("Light") { ThemeSwatches() }
#Preview("Dark") { ThemeSwatches().preferredColorScheme(.dark) }
#endif
