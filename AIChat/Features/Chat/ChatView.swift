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
                    MessageRow(message: message)
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
                .padding(.bottom, 12)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: viewModel.showsScrollToBottomButton)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(
                text: $viewModel.inputText,
                isGenerating: viewModel.isGenerating,
                canSend: viewModel.canSend,
                onSend: send,
                onStop: { viewModel.stop() }
            )
        }
        .background(.appBackground)
        .task(id: viewModel.chatId) { await viewModel.observeMessages() }
        .task(id: viewModel.chatId) { await viewModel.observeDraft() }
        .alert("Message not sent", isPresented: sendFailedBinding) {
            Button("OK", role: .cancel) { viewModel.dismissSendFailure() }
        } message: {
            Text("Please try again.")
        }
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

/// Одно сообщение: пузырь пользователя справа или ответ ассистента на всю ширину.
struct MessageRow: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .user: UserBubble(text: message.text)
        case .assistant: AssistantText(text: message.text)
        }
    }
}

private struct UserBubble: View {
    let text: String

    var body: some View {
        // Текст сообщения — пользовательские данные, а не строка интерфейса.
        Text(text)
            .textStyle(.userMessage)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.appSurface, in: .rect(cornerRadius: 20))
            .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.8 }
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct AssistantText: View {
    let text: String

    var body: some View {
        // Блочный markdown — шаг 4.7; пока только инлайн-разметка.
        Text(Self.inlineMarkdown(text))
            .textStyle(.assistantMessage)
            .foregroundStyle(.primary)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Плавное появление новых токенов.
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.25), value: text)
    }

    private static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

#if DEBUG
private struct ChatViewPreview: View {
    @State private var viewModel: ChatViewModel

    init(chat: Chat = PreviewData.swiftChat) {
        let dependencies = ChatDependencies.preview()
        _viewModel = State(initialValue: ChatViewModel(chatId: chat.id,
                                                       repository: dependencies.repository,
                                                       session: dependencies.session))
    }

    var body: some View {
        ChatView(viewModel: viewModel)
    }
}

#Preview("Light") { ChatViewPreview() }
#Preview("Dark") { ChatViewPreview().preferredColorScheme(.dark) }
#Preview("Errors") { ChatViewPreview(chat: PreviewData.errorsChat) }
#endif
