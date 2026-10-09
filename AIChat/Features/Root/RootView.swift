import SwiftUI

/// Корневой экран. iPhone (compact) — свой выезжающий сайдбар поверх экрана чата;
/// iPad/Mac (regular) — `NavigationSplitView`. Верхняя панель своя в обоих случаях.
struct RootView: View {
    private let dependencies: ChatDependencies
    @State private var chatList: ChatListViewModel
    @State private var connectivity: ConnectivityStatus
    @State private var isSidebarOpen = false
    @State private var isSettingsPresented = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(dependencies: ChatDependencies) {
        self.dependencies = dependencies
        _chatList = State(initialValue: ChatListViewModel(repository: dependencies.repository,
                                                          session: dependencies.session))
        _connectivity = State(initialValue: ConnectivityStatus(monitor: dependencies.connectivity))
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                splitLayout
            } else {
                drawerLayout
            }
        }
        .chatListAlerts(chatList)
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(dependencies: dependencies)
                .presentationDetents([.large])
                .presentationSizing(.form)
        }
        .task { await chatList.observe() }
        .task { await connectivity.observe() }
    }

    private var drawerLayout: some View {
        SideDrawer(isOpen: $isSidebarOpen) {
            SidebarView(viewModel: chatList,
                        onNavigate: { withAnimation(.snappy) { isSidebarOpen = false } },
                        onOpenSettings: { isSettingsPresented = true })
        } content: {
            chatScreen {
                withAnimation(.snappy) { isSidebarOpen.toggle() }
            }
        }
        .onChange(of: isSidebarOpen) { _, isOpen in
            if isOpen { dismissKeyboard() }
        }
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: chatList, onOpenSettings: { isSettingsPresented = true })
                .toolbar(.hidden, for: .navigationBar)
        } detail: {
            chatScreen {
                withAnimation { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func chatScreen(onToggleSidebar: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            ChatTopBar(
                chat: chatList.selectedChat,
                modelName: dependencies.modelName,
                onToggleSidebar: onToggleSidebar,
                onRename: { chatList.beginRename($0) },
                onNewChat: { chatList.startNewChat() }
            )
            if !connectivity.isOnline {
                OfflineBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ChatScreenContent(chatId: chatList.selectedChatId, dependencies: dependencies) { id in
                chatList.didCreateChat(id: id)
            }
            .id(chatList.screenID)
                .frame(maxHeight: .infinity)
        }
        .animation(.snappy, value: connectivity.isOnline)
        .background(.appBackground)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// Тело экрана чата. Пересоздаётся, когда пользователь выбирает другой чат
/// (`screenID`), но не когда новый чат получил id после первой отправки.
private struct ChatScreenContent: View {
    @State private var viewModel: ChatViewModel

    init(chatId: UUID?, dependencies: ChatDependencies, onChatCreated: @escaping (UUID) -> Void) {
        _viewModel = State(initialValue: ChatViewModel(chatId: chatId,
                                                       repository: dependencies.repository,
                                                       session: dependencies.session,
                                                       onChatCreated: onChatCreated,
                                                       copyToClipboard: { UIPasteboard.general.string = $0 },
                                                       speech: dependencies.speech,
                                                       recorder: dependencies.recorder,
                                                       transcriber: dependencies.transcriber,
                                                       prepareImage: dependencies.prepareImage,
                                                       openSettings: dependencies.openAppSettings))
    }

    var body: some View {
        ChatView(viewModel: viewModel)
    }
}

#if DEBUG
#Preview("Light") { RootView(dependencies: .preview()) }
#Preview("Dark") { RootView(dependencies: .preview()).preferredColorScheme(.dark) }
#Preview("iPad", traits: .landscapeLeft) {
    RootView(dependencies: .preview()).environment(\.horizontalSizeClass, .regular)
}
#endif
