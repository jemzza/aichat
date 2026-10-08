import SwiftUI

/// Лента сообщений и поле ввода. Автоскролл — только если пользователь внизу;
/// иначе показывается кнопка «вниз».
struct ChatView: View {
    @Bindable var viewModel: ChatViewModel

    @State private var position = ScrollPosition(edge: .bottom)
    /// Последнее известное «у нижнего края» — применяется, когда пользователь отпустил ленту.
    @State private var isNearBottom = true
    @State private var isUserScrolling = false

    /// Насколько можно не доскроллить до конца и всё ещё считаться «внизу».
    private let bottomTolerance: CGFloat = 48

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(viewModel.displayedMessages) { message in
                    MessageRow(message: message, actions: actions(for: message))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height + geometry.contentInsets.bottom - bottomTolerance
        } action: { _, isNearBottom in
            self.isNearBottom = isNearBottom
            if isUserScrolling { viewModel.userScrolled(isAtBottom: isNearBottom) }
        }
        .onScrollPhaseChange { _, phase in
            // Программная прокрутка (`.animating`) и рост контента не снимают «прилипание» к низу.
            isUserScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
            if phase == .idle || isUserScrolling { viewModel.userScrolled(isAtBottom: isNearBottom) }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
            if new > old, viewModel.isPinnedToBottom, !isUserScrolling {
                position.scrollTo(edge: .bottom)
            }
        }
        // Клавиатура или выросшее поле ввода уменьшают ленту — остаёмся внизу.
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { old, new in
            if new < old, viewModel.isPinnedToBottom { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottom) {
            if viewModel.showsScrollToBottomButton {
                ScrollToBottomButton {
                    viewModel.scrollToBottomTapped()
                    withAnimation(.snappy) { position.scrollTo(edge: .bottom) }
                }
                // Плавающая кнопка поверх текста: растёт, но не закрывает пол-экрана.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .padding(.bottom, 12)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: viewModel.showsScrollToBottomButton)
        .overlay {
            if viewModel.showsEmptyState {
                EmptyChatView(greeting: viewModel.greeting, suggestions: viewModel.suggestions) { suggestion in
                    Task { await viewModel.send(suggestion: suggestion) }
                }
                .background(.appBackground)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: viewModel.showsEmptyState)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(
                text: $viewModel.inputText,
                isGenerating: viewModel.isGenerating,
                canSend: viewModel.canSend,
                dictation: composerDictation,
                onSend: send,
                onStop: { viewModel.stop() }
            )
        }
        .background(.appBackground)
        .task(id: viewModel.chatId) { await viewModel.observeMessages() }
        .task(id: viewModel.chatId) { await viewModel.observeDraft() }
        .task { await viewModel.observeSpeech() }
        .onDisappear { viewModel.stopDictation() }
        .alert("Message not sent", isPresented: sendFailedBinding) {
            Button("OK", role: .cancel) { viewModel.dismissSendFailure() }
        } message: {
            Text("Please try again.")
        }
        .alert("Couldn't retry", isPresented: retryFailedBinding) {
            Button("OK", role: .cancel) { viewModel.dismissRetryFailure() }
        } message: {
            Text("Please try again.")
        }
        .alert("Couldn't answer offline", isPresented: offlineAnswerFailedBinding) {
            Button("OK", role: .cancel) { viewModel.dismissOfflineAnswerFailure() }
        } message: {
            Text("Please try again.")
        }
    }

    private var offlineAnswerFailedBinding: Binding<Bool> {
        Binding { viewModel.offlineAnswerFailed } set: { if !$0 { viewModel.dismissOfflineAnswerFailure() } }
    }

    private var retryFailedBinding: Binding<Bool> {
        Binding { viewModel.retryFailed } set: { if !$0 { viewModel.dismissRetryFailure() } }
    }

    private func actions(for message: Message) -> MessageActions {
        MessageActions(
            canRetry: viewModel.canRetry(message),
            isCopied: viewModel.copiedMessageId == message.id,
            canReadAloud: viewModel.canReadAloud(message),
            isReadingAloud: viewModel.speakingMessageId == message.id,
            canAnswerOffline: viewModel.canAnswerOffline(message),
            copy: { viewModel.copy(message) },
            toggleReadAloud: { viewModel.toggleReadAloud(message) },
            retry: { Task { await viewModel.retry(message) } },
            copyText: { viewModel.copyText($0) },
            answerOffline: { Task { await viewModel.answerOffline(message) } }
        )
    }

    private var composerDictation: ComposerDictation? {
        guard let dictation = viewModel.dictation else { return nil }
        return ComposerDictation(
            state: dictation.state,
            level: dictation.level,
            canOpenSettings: dictation.canOpenSettings,
            toggle: { Task { await viewModel.toggleDictation() } },
            openSettings: { dictation.openSettings() },
            dismissMessage: { dictation.dismissMessage() }
        )
    }

    private func send() {
        Task {
            await viewModel.send()
            position.scrollTo(edge: .bottom)
        }
    }

    private var sendFailedBinding: Binding<Bool> {
        Binding { viewModel.sendFailed } set: { if !$0 { viewModel.dismissSendFailure() } }
    }
}

private struct ScrollToBottomButton: View {
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 40

    var body: some View {
        Button("Scroll to bottom", systemImage: "arrow.down", action: action)
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            // Фон экрана, а не `Surface`: кнопка часто лежит поверх пузыря пользователя.
            .background(.appBackground, in: .circle)
            .overlay { Circle().strokeBorder(.secondary.opacity(0.35)) }
            .shadow(color: .primary.opacity(0.08), radius: 6, y: 2)
            .contentShape(.circle)
    }
}

#if DEBUG
private struct ChatViewPreview: View {
    @State private var viewModel: ChatViewModel

    init(chat: Chat = PreviewData.swiftChat) {
        let dependencies = ChatDependencies.preview()
        _viewModel = State(initialValue: ChatViewModel(chatId: chat.id,
                                                       repository: dependencies.repository,
                                                       session: dependencies.session,
                                                       speech: dependencies.speech,
                                                       transcriber: dependencies.transcriber))
    }

    var body: some View {
        ChatView(viewModel: viewModel)
    }
}

#Preview("Light") { ChatViewPreview() }
#Preview("Dark") { ChatViewPreview().preferredColorScheme(.dark) }
#Preview("Errors") { ChatViewPreview(chat: PreviewData.errorsChat) }
#endif
