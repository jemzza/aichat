import SwiftUI

/// Что можно сделать с ответом. Собирает `ChatView` из `ChatViewModel`.
struct MessageActions {
    var canRetry = false
    var isCopied = false
    var copy: () -> Void = {}
    var retry: () -> Void = {}
    /// Копирование блока кода из ответа.
    var copyText: (String) -> Void = { _ in }
}

/// Одно сообщение: пузырь пользователя справа или ответ ассистента на всю ширину
/// вместе с его состоянием (генерация, ошибка, «Stopped», действия).
struct MessageRow: View {
    let message: Message
    var actions = MessageActions()

    var body: some View {
        switch message.role {
        case .user: UserMessage(message: message)
        case .assistant: AssistantMessage(message: message, actions: actions)
        }
    }
}

// MARK: - Пользователь

private struct UserMessage: View {
    let message: Message

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // Текст сообщения — пользовательские данные, а не строка интерфейса.
            Text(message.text)
                .textStyle(.userMessage)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.appSurface, in: .rect(cornerRadius: 20))

            if message.status == .pending {
                Label("Will send when online", systemImage: "clock")
                    .textStyle(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.8 }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Ассистент

private struct AssistantMessage: View {
    let message: Message
    let actions: MessageActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.text.isEmpty {
                MarkdownView(text: message.text, copyCode: actions.copyText)
                    .textStyle(.assistantMessage)
                    .foregroundStyle(.primary)
                    .animation(.easeOut(duration: 0.25), value: message.text)
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: message.status)
    }

    @ViewBuilder
    private var footer: some View {
        switch message.status {
        case .streaming:
            GeneratingIndicator()
        case .done:
            ActionIcons(message: message, actions: actions, showsRetry: false)
        case .cancelled:
            // При крупном шрифте подпись и иконки не помещаются в строку — переносим.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    stoppedLabel
                    ActionIcons(message: message, actions: actions, showsRetry: true, alignsToTextEdge: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    stoppedLabel
                    ActionIcons(message: message, actions: actions, showsRetry: true)
                }
            }
        case .failed, .interrupted:
            if let presentation = MessageErrorPresentation.forMessage(message) {
                ErrorBanner(presentation: presentation, failure: message.failure, actions: actions)
            }
            if !message.text.isEmpty {
                ActionIcons(message: message, actions: actions, showsRetry: false)
            }
        case .pending, .sent:
            EmptyView()
        }
    }

    private var stoppedLabel: some View {
        Label("Stopped", systemImage: "stop.circle")
            .textStyle(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// Три пульсирующие точки: ответ генерируется (до первого токена — это и есть «загрузка»).
private struct GeneratingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var dotSize: CGFloat = 7

    var body: some View {
        HStack(spacing: dotSize * 0.6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: dotSize, height: dotSize)
                    .phaseAnimator([0.3, 1.0], trigger: reduceMotion) { dot, phase in
                        dot.opacity(reduceMotion ? 0.6 : phase)
                    } animation: { _ in
                        .easeInOut(duration: 0.5).delay(Double(index) * 0.15)
                    }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement()
        .accessibilityLabel(Text("Generating response"))
    }
}

/// Маленькие иконки под ответом: копировать и (для остановленного) повторить.
private struct ActionIcons: View {
    let message: Message
    let actions: MessageActions
    let showsRetry: Bool
    /// Первый в строке — сдвигаем, чтобы иконка стояла вровень с текстом ответа.
    var alignsToTextEdge = true

    var body: some View {
        HStack(spacing: 4) {
            if !message.text.isEmpty {
                IconButton(
                    title: actions.isCopied ? "Copied" : "Copy",
                    systemImage: actions.isCopied ? "checkmark" : "doc.on.doc",
                    action: actions.copy
                )
                .contentTransition(.symbolEffect(.replace))
                .sensoryFeedback(.success, trigger: actions.isCopied) { _, isCopied in isCopied }
            }
            if showsRetry {
                IconButton(title: "Retry", systemImage: "arrow.clockwise", action: actions.retry)
                    .disabled(!actions.canRetry)
            }
        }
        // Кнопки 44pt, а иконки должны стоять вровень с текстом ответа.
        .padding(.leading, alignsToTextEdge ? -12 : 0)
        // Иконки растут с текстом, но не настолько, чтобы закрывать ответ.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

private struct IconButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(minWidth: 44, minHeight: 32)
            .contentShape(.rect)
    }
}

/// Спокойная плашка ошибки под ответом: иконка, понятный текст, «Retry».
/// При 429 с `retry-after` — обратный отсчёт, «Retry» неактивна до его конца.
private struct ErrorBanner: View {
    let presentation: MessageErrorPresentation
    let failure: MessageFailure?
    let actions: MessageActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = MessageErrorPresentation.secondsUntilRetry(failure, now: context.date)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    message(wait: wait)
                    Spacer(minLength: 0)
                    retryButton(wait: wait)
                }
                VStack(alignment: .leading, spacing: 10) {
                    message(wait: wait)
                    retryButton(wait: wait)
                }
            }
        }
        // Во вертикальной раскладке (узкий экран, крупный шрифт) плашка всё равно на всю ширину.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.appSurface, in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.2)) }
    }

    private func message(wait: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                if let wait {
                    Text("Try again in \(wait) s")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func retryButton(wait: Int?) -> some View {
        Button("Retry", action: actions.retry)
            .font(.subheadline.weight(.medium))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.appAccent)
            .disabled(!actions.canRetry || wait != nil)
    }
}

#if DEBUG
private struct MessageStatesPreview: View {
    private static let chatId = UUID()
    private static let now = Date()

    private static func reply(_ text: String, _ status: MessageStatus, failure: MessageFailure? = nil) -> Message {
        Message(chatId: chatId, role: .assistant, text: text, status: status, failure: failure, createdAt: now)
    }

    private let messages: [Message] = [
        Message(chatId: chatId, role: .user, text: "Then with banana instead?", status: .pending, createdAt: now),
        reply("", .streaming),
        reply("The compiler checks isolation for you", .streaming),
        reply("A finished answer with **bold** text.", .done),
        reply("Consider Porto: it is smaller and", .cancelled),
        reply("Trains between Lisbon and", .interrupted),
        reply("", .failed, failure: MessageFailure(kind: .rateLimited, retryAt: now.addingTimeInterval(30))),
        reply("", .failed, failure: MessageFailure(kind: .offline)),
        reply("", .failed, failure: MessageFailure(kind: .forbidden)),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(messages) { message in
                    MessageRow(message: message, actions: MessageActions(canRetry: true))
                }
            }
            .padding()
        }
        .background(.appBackground)
    }
}

#Preview("Light") { MessageStatesPreview() }
#Preview("Dark") { MessageStatesPreview().preferredColorScheme(.dark) }
#endif
