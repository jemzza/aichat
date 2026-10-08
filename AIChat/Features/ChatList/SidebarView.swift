import SwiftUI

/// Сайдбар: «New chat», поиск, «Recents» по датам. Одна и та же вью — и в
/// выезжающей панели на iPhone, и в колонке `NavigationSplitView` на iPad.
/// Алерты переименования/удаления вешает `RootView`: они общие с верхней панелью.
struct SidebarView: View {
    @Bindable var viewModel: ChatListViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Вызывается после выбора чата или «New chat» — iPhone закрывает панель.
    var onNavigate: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(.appBackground)
    }

    private var header: some View {
        VStack(spacing: 12) {
            SearchField(text: $viewModel.searchText)

            Button {
                viewModel.startNewChat()
                onNavigate()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.appAccent)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isEmpty {
            ContentUnavailableView {
                Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Your conversations will appear here.")
            }
        } else if viewModel.hasNoSearchResults {
            ContentUnavailableView.search(text: viewModel.searchText)
        } else {
            chatList
        }
    }

    private var chatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text("Recents")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 16)
                ForEach(viewModel.sections) { section in
                    Text(section.group.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.chats) { chat in
                        row(for: chat)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func row(for chat: Chat) -> some View {
        let isSelected = chat.id == viewModel.selectedChatId
        return Button {
            viewModel.select(chat)
            onNavigate()
        } label: {
            // Название чата — пользовательские данные, а не строка интерфейса.
            Text(chat.title)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isSelected ? AnyShapeStyle(.appSurface) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 10))
                .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("Rename", systemImage: "pencil") { viewModel.beginRename(chat) }
            Button("Delete", systemImage: "trash", role: .destructive) { viewModel.requestDelete(chat) }
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.appSurface, in: .rect(cornerRadius: 12))
    }
}

/// Алерты переименования, подтверждения удаления и ошибки действия — общие для
/// сайдбара и верхней панели чата.
struct ChatListAlerts: ViewModifier {
    @Bindable var viewModel: ChatListViewModel

    func body(content: Content) -> some View {
        content
            .alert("Rename chat", isPresented: renameBinding) {
                TextField("Title", text: $viewModel.renameText)
                Button("Cancel", role: .cancel) { viewModel.cancelRename() }
                Button("Save") { viewModel.commitRename() }
                    .disabled(!viewModel.canCommitRename)
            }
            .confirmationDialog(
                "Delete this chat?",
                isPresented: deleteBinding,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { viewModel.confirmDelete() }
                Button("Cancel", role: .cancel) { viewModel.chatPendingDeletion = nil }
            } message: {
                Text("The chat and all its messages will be removed.")
            }
            .alert("Something went wrong", isPresented: failureBinding) {
                Button("OK", role: .cancel) { viewModel.dismissActionFailure() }
            } message: {
                Text("Please try again.")
            }
    }

    private var renameBinding: Binding<Bool> {
        Binding { viewModel.renamingChat != nil } set: { if !$0 { viewModel.cancelRename() } }
    }

    private var deleteBinding: Binding<Bool> {
        Binding { viewModel.chatPendingDeletion != nil } set: { if !$0 { viewModel.chatPendingDeletion = nil } }
    }

    private var failureBinding: Binding<Bool> {
        Binding { viewModel.actionFailed } set: { if !$0 { viewModel.dismissActionFailure() } }
    }
}

extension View {
    func chatListAlerts(_ viewModel: ChatListViewModel) -> some View {
        modifier(ChatListAlerts(viewModel: viewModel))
    }
}

#if DEBUG
private struct SidebarPreview: View {
    @State private var viewModel: ChatListViewModel

    init(dependencies: ChatDependencies) {
        _viewModel = State(initialValue: ChatListViewModel(repository: dependencies.repository,
                                                           session: dependencies.session))
    }

    var body: some View {
        SidebarView(viewModel: viewModel)
            .chatListAlerts(viewModel)
            .task { await viewModel.observe() }
    }
}

#Preview("Light") { SidebarPreview(dependencies: .preview()) }
#Preview("Dark") { SidebarPreview(dependencies: .preview()).preferredColorScheme(.dark) }
#Preview("Empty") { SidebarPreview(dependencies: .preview(repository: InMemoryChatRepository())) }
#endif
