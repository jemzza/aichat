import SwiftUI

/// Пустой экран нового чата: приветствие по времени суток и подсказки-чипы.
struct EmptyChatView: View {
    let greeting: Greeting
    let suggestions: [Suggestion]
    let onSelect: (Suggestion) -> Void

    var body: some View {
        // Короткий контент — по центру экрана; длинный (крупный шрифт) — прокручивается с начала.
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
            VStack(spacing: 28) {
                Text(greeting.title)
                    .textStyle(.greeting)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 10) {
                    ForEach(suggestions) { suggestion in
                        SuggestionChip(suggestion: suggestion) { onSelect(suggestion) }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: 520)
    }
}

private struct SuggestionChip: View {
    let suggestion: Suggestion
    let action: () -> Void

    /// Общая ширина иконок — тексты чипов начинаются ровно.
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 20

    var body: some View {
        Button(action: action) {
            Label {
                Text(suggestion.prompt)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: suggestion.systemImage)
                    .foregroundStyle(.appAccent)
                    .frame(width: iconWidth)
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.appSurface, in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary.opacity(0.2)) }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("Light") {
    EmptyChatView(greeting: .morning, suggestions: Suggestion.all, onSelect: { _ in })
        .background(.appBackground)
}

#Preview("Dark") {
    EmptyChatView(greeting: .evening, suggestions: Suggestion.all, onSelect: { _ in })
        .background(.appBackground)
        .preferredColorScheme(.dark)
}
#endif
