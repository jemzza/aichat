import SwiftUI

/// Своя верхняя панель (одинаково выглядит на iOS 18 и 26): слева — сайдбар,
/// по центру — название чата (нажатие — переименовать) и модель, справа — новый чат.
struct ChatTopBar: View {
    /// `nil` — новый чат, ещё не сохранённый.
    let chat: Chat?
    let modelName: LocalizedStringResource
    let onToggleSidebar: () -> Void
    let onRename: (Chat) -> Void
    let onNewChat: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            iconButton("Show sidebar", systemImage: "sidebar.leading", action: onToggleSidebar)

            Button {
                if let chat { onRename(chat) }
            } label: {
                VStack(spacing: 2) {
                    title
                        .textStyle(.chatTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(modelName)
                        .textStyle(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // Не `.disabled`: заголовок нового чата не должен выглядеть неактивным.
            .allowsHitTesting(chat != nil)
            .accessibilityHint(Text("Rename chat"))

            iconButton("New chat", systemImage: "square.and.pencil", action: onNewChat)
                .disabled(chat == nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // Как у системных навбаров: панель не растёт бесконечно, иначе съедает экран.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background(.appBackground)
    }

    private var title: Text {
        // Название — пользовательские данные; заглушка нового чата — из каталога.
        if let chat { Text(chat.title) } else { Text("New chat") }
    }

    private func iconButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.title3)
            .foregroundStyle(.primary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
    }
}

#if DEBUG
private struct ChatTopBarPreview: View {
    var body: some View {
        VStack(spacing: 24) {
            ChatTopBar(chat: PreviewData.swiftChat, modelName: "Groq · gpt-oss-120b",
                       onToggleSidebar: {}, onRename: { _ in }, onNewChat: {})
            ChatTopBar(chat: nil, modelName: "Groq · gpt-oss-120b",
                       onToggleSidebar: {}, onRename: { _ in }, onNewChat: {})
            Spacer()
        }
        .background(.appBackground)
    }
}

#Preview("Light") { ChatTopBarPreview() }
#Preview("Dark") { ChatTopBarPreview().preferredColorScheme(.dark) }
#endif
