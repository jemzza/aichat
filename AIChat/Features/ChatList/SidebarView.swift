import SwiftUI

/// Сайдбар: «New chat», поиск, папки, «Recents» по датам. Одна и та же вью — и в
/// выезжающей панели на iPhone, и в колонке `NavigationSplitView` на iPad.
/// Алерты переименования/удаления вешает `RootView`: они общие с верхней панелью.
struct SidebarView: View {
    @Bindable var viewModel: ChatListViewModel
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
                if !viewModel.isSearching {
                    SidebarSectionHeader(title: "Folders") {
                        Button("New folder", systemImage: "folder.badge.plus") { viewModel.beginCreateFolder() }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.appAccent)
                            .buttonStyle(.plain)
                    }
                }
                ForEach(viewModel.folderSections) { item in
                    FolderSection(item: item, viewModel: viewModel, onNavigate: onNavigate)
                }
                if !viewModel.isSearching || !viewModel.sections.isEmpty {
                    RecentsHeader(viewModel: viewModel)
                }
                ForEach(viewModel.sections) { section in
                    Text(section.group.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.chats) { chat in
                        ChatRow(chat: chat, viewModel: viewModel, onNavigate: onNavigate)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.immediately)
    }
}

/// Папка с её чатами — один элемент `LazyVStack`: строки чатов получают свою
/// идентичность внутри папки и не путаются с теми же чатами, пока они были в «Recents».
private struct FolderSection: View {
    let item: FolderSectionItem
    let viewModel: ChatListViewModel
    let onNavigate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            FolderRow(item: item, viewModel: viewModel)
            if item.isExpanded {
                ForEach(item.chats) { chat in
                    ChatRow(chat: chat, viewModel: viewModel, isNested: true, onNavigate: onNavigate)
                }
                if item.chats.isEmpty {
                    Text("No chats yet")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 36)
                        .padding(.vertical, 6)
                }
            }
        }
    }
}

/// Заголовок «Recents» — он же цель перетаскивания «убрать из папки».
private struct RecentsHeader: View {
    let viewModel: ChatListViewModel
    @State private var isDropTargeted = false

    var body: some View {
        SidebarSectionHeader(title: "Recents")
            .padding(.bottom, 4)
            .dropHighlight(isDropTargeted)
            .dropDestination(for: ChatDragItem.self) { items, _ in
                viewModel.dropChats(items.map(\.chatId), into: nil)
            } isTargeted: { isDropTargeted = $0 }
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
            .alert(folderNameTitle, isPresented: folderNameBinding) {
                TextField("Name", text: $viewModel.folderNameText)
                Button("Cancel", role: .cancel) { viewModel.cancelFolderNameEditing() }
                Button(folderNameConfirmTitle) { viewModel.commitFolderName() }
                .disabled(!viewModel.canCommitFolderName)
            }
            .confirmationDialog(
                "Delete this folder?",
                isPresented: deleteFolderBinding,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { viewModel.confirmDeleteFolder() }
                Button("Cancel", role: .cancel) { viewModel.folderPendingDeletion = nil }
            } message: {
                Text("Chats in it will move to Recents.")
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

    private var folderNameTitle: LocalizedStringKey {
        viewModel.folderNameEditing == .create ? "New folder" : "Rename folder"
    }

    private var folderNameConfirmTitle: LocalizedStringKey {
        viewModel.folderNameEditing == .create ? "Create" : "Save"
    }

    private var folderNameBinding: Binding<Bool> {
        Binding { viewModel.folderNameEditing != nil } set: { if !$0 { viewModel.cancelFolderNameEditing() } }
    }

    private var deleteFolderBinding: Binding<Bool> {
        Binding { viewModel.folderPendingDeletion != nil } set: { if !$0 { viewModel.folderPendingDeletion = nil } }
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
#Preview("Empty · Dark") {
    SidebarPreview(dependencies: .preview(repository: InMemoryChatRepository())).preferredColorScheme(.dark)
}
#Preview("Folders") { SidebarPreview(dependencies: .preview(repository: PreviewData.repositoryWithFolders())) }
#Preview("Folders · Dark") {
    SidebarPreview(dependencies: .preview(repository: PreviewData.repositoryWithFolders())).preferredColorScheme(.dark)
}
#endif
