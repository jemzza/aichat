import SwiftUI

/// Поле ввода: карточка с тонкой обводкой, многострочное поле (растёт до 6 строк),
/// справа внизу круглая кнопка «Send», во время генерации — «Stop».
struct ComposerView: View {
    @Binding var text: String
    let isGenerating: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool
    @State private var sendCount = 0
    @State private var stopCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Message…", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textStyle(.userMessage)
                .focused($isFocused)
                .padding(.horizontal, 4)
                .padding(.top, 4)

            HStack {
                Spacer()
                actionButton
            }
        }
        .padding(10)
        .background(.appSurface, in: .rect(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24).strokeBorder(.secondary.opacity(0.25))
        }
        .contentShape(.rect(cornerRadius: 24))
        .onTapGesture { isFocused = true }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .sensoryFeedback(.impact(weight: .medium), trigger: sendCount)
        .sensoryFeedback(.impact(weight: .light), trigger: stopCount)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isGenerating {
            CircleButton(title: "Stop", systemImage: "stop.fill", isEnabled: true, isProminent: false) {
                stopCount += 1
                onStop()
            }
        } else {
            CircleButton(title: "Send", systemImage: "arrow.up", isEnabled: canSend, isProminent: true) {
                sendCount += 1
                onSend()
            }
        }
    }
}

private struct CircleButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isEnabled: Bool
    /// «Send» — акцентная; «Stop» — нейтральная (цвет текста).
    let isProminent: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 34

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.45, weight: .bold))
            // Белый на акценте и фон экрана на `.primary` контрастны в обеих темах.
            .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.appBackground))
            .frame(width: size, height: size)
            .background(background, in: .circle)
            .contentShape(.circle)
            .disabled(!isEnabled)
            .animation(.snappy, value: isEnabled)
    }

    private var background: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(.secondary.opacity(0.35)) }
        return isProminent ? AnyShapeStyle(.appAccent) : AnyShapeStyle(.primary)
    }
}

#if DEBUG
private struct ComposerPreview: View {
    @State private var empty = ""
    @State private var filled = "What is an actor in Swift?"
    @State private var long = (1...8).map { "Line \($0)" }.joined(separator: "\n")

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ComposerView(text: $empty, isGenerating: false, canSend: false, onSend: {}, onStop: {})
            ComposerView(text: $filled, isGenerating: false, canSend: true, onSend: {}, onStop: {})
            ComposerView(text: $filled, isGenerating: true, canSend: false, onSend: {}, onStop: {})
            ComposerView(text: $long, isGenerating: false, canSend: true, onSend: {}, onStop: {})
        }
        .background(.appBackground)
    }
}

#Preview("Light") { ComposerPreview() }
#Preview("Dark") { ComposerPreview().preferredColorScheme(.dark) }
#endif
