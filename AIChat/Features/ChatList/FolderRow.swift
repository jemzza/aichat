import SwiftUI

/// Строка папки: свернуть/развернуть, приём перетаскиваемых чатов, контекстное меню.
struct FolderRow: View {
    let item: FolderSectionItem
    let viewModel: ChatListViewModel
    @State private var isDropTargeted = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button {
            withAnimation(.snappy) { viewModel.toggleExpanded(item.folder) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(item.isExpanded ? 90 : 0))
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                // Имя папки — пользовательские данные.
                Text(item.folder.name)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.totalCount, format: .number)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .dropHighlight(isDropTargeted)
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .dropDestination(for: ChatDragItem.self) { items, _ in
            viewModel.dropChats(items.map(\.chatId), into: item.folder.id)
        } isTargeted: { isDropTargeted = $0 }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { viewModel.beginRenameFolder(item.folder) }
            Button("Move Up", systemImage: "arrow.up") {
                Task { await viewModel.moveFolderUp(item.folder) }
            }
            .disabled(!item.canMoveUp)
            Button("Move Down", systemImage: "arrow.down") {
                Task { await viewModel.moveFolderDown(item.folder) }
            }
            .disabled(!item.canMoveDown)
            Button("Delete", systemImage: "trash", role: .destructive) {
                viewModel.requestDeleteFolder(item.folder)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(item.folder.name), \(item.totalCount) chats"))
        .accessibilityValue(item.isExpanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityAddTraits(.isButton)
    }
}

/// Заголовок секции сайдбара («Folders», «Recents»).
struct SidebarSectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

extension SidebarSectionHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey) {
        self.init(title: title) { EmptyView() }
    }
}

extension View {
    /// Подсветка цели перетаскивания: фон `Surface` и обводка `Accent`.
    func dropHighlight(_ isTargeted: Bool) -> some View {
        background(isTargeted ? AnyShapeStyle(.appSurface) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.appAccent, lineWidth: 1.5)
                    .opacity(isTargeted ? 1 : 0)
            }
            .animation(.snappy, value: isTargeted)
    }
}
