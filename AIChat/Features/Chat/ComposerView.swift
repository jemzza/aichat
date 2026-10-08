import PhotosUI
import SwiftUI

/// Фото во вложении. Собирает `ChatView` из `ChatViewModel`.
struct ComposerAttachments {
    var images: [ImageAttachment] = []
    /// Сколько ещё можно выбрать; 0 — «+» неактивна.
    var remainingSlots = ImageAttachment.maxPerMessage
    var isPreparing = false
    /// `nil` в массиве — фото не удалось загрузить из библиотеки.
    var add: ([Data?]) -> Void = { _ in }
    var remove: (UUID) -> Void = { _ in }
}

/// Диктовка в поле ввода. Собирает `ChatView` из `DictationViewModel`.
struct ComposerDictation {
    var state = DictationViewModel.State.idle
    var level: Float = 0
    var canOpenSettings = false
    var toggle: () -> Void = {}
    var openSettings: () -> Void = {}
    var dismissMessage: () -> Void = {}
}

/// Поле ввода: карточка с тонкой обводкой, многострочное поле (растёт до 6 строк),
/// справа внизу микрофон и круглая кнопка «Send», во время генерации — «Stop».
/// Во время диктовки — акцентная обводка, индикатор «Listening…» и «Done» вместо микрофона.
struct ComposerView: View {
    @Binding var text: String
    let isGenerating: Bool
    let canSend: Bool
    /// `nil` — диктовки нет.
    var dictation: ComposerDictation?
    /// `nil` — кнопки «+» нет.
    var attachments: ComposerAttachments?
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool
    @State private var sendCount = 0
    @State private var stopCount = 0

    var body: some View {
        VStack(spacing: 6) {
            if let dictation, let message = DictationMessagePresentation(state: dictation.state) {
                DictationMessage(presentation: message, dictation: dictation)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            card
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        // Непрозрачно на всю ширину: лента не должна просвечивать вокруг карточки.
        .background(.appBackground)
        .animation(.snappy, value: dictation?.state)
        .sensoryFeedback(.impact(weight: .medium), trigger: sendCount)
        .sensoryFeedback(.impact(weight: .light), trigger: stopCount)
        .sensoryFeedback(.start, trigger: dictation?.state == .recording) { _, isRecording in isRecording }
    }

    private var isRecording: Bool { dictation?.state == .recording }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let attachments, !attachments.images.isEmpty || attachments.isPreparing {
                AttachmentStrip(attachments: attachments)
            }
            TextField("Message…", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textStyle(.userMessage)
                .focused($isFocused)
                .padding(.horizontal, 4)
                .padding(.top, 4)

            HStack(spacing: 8) {
                if let attachments {
                    AddPhotoButton(attachments: attachments)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                }
                if let dictation {
                    DictationStatus(state: dictation.state, level: dictation.level)
                }
                Spacer(minLength: 0)
                Group {
                    if let dictation {
                        DictationButton(state: dictation.state, action: dictation.toggle)
                    }
                    actionButton
                }
                // Кнопки растут с текстом, но не до размеров, съедающих поле ввода.
                // На месте вызова: `@ScaledMetric` кнопки читает окружение родителя.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
        .padding(10)
        .background(.appSurface, in: .rect(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(isRecording ? AnyShapeStyle(.appAccent) : AnyShapeStyle(.secondary.opacity(0.25)),
                              lineWidth: isRecording ? 1.5 : 1)
        }
        .contentShape(.rect(cornerRadius: 24))
        .onTapGesture { isFocused = true }
        .padding(.horizontal, 12)
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

/// «+» слева внизу: выбор фото из библиотеки (`PhotosPicker`, без доступа ко всей медиатеке).
private struct AddPhotoButton: View {
    let attachments: ComposerAttachments

    @State private var isPickerPresented = false
    @State private var selection: [PhotosPickerItem] = []
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 34

    var body: some View {
        Button("Add photo", systemImage: "plus") { isPickerPresented = true }
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .overlay { Circle().strokeBorder(.secondary.opacity(0.35)) }
            .contentShape(.circle)
            .disabled(attachments.remainingSlots == 0 || attachments.isPreparing)
            .photosPicker(isPresented: $isPickerPresented, selection: $selection,
                          maxSelectionCount: max(attachments.remainingSlots, 1),
                          selectionBehavior: .ordered, matching: .images)
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                selection = []
                let add = attachments.add
                Task {
                    var originals: [Data?] = []
                    for item in items {
                        originals.append(try? await item.loadTransferable(type: Data.self))
                    }
                    add(originals)
                }
            }
    }
}

/// Миниатюры выбранных фото над полем ввода, у каждой — «Remove photo».
private struct AttachmentStrip: View {
    let attachments: ComposerAttachments

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 64

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments.images) { image in
                    AttachmentThumbnail(attachment: image, side: side)
                        .overlay(alignment: .topTrailing) {
                            Button("Remove photo", systemImage: "xmark.circle.fill") {
                                attachments.remove(image.id)
                            }
                            .labelStyle(.iconOnly)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .font(.title3)
                            .padding(2)
                        }
                }
                if attachments.isPreparing {
                    ProgressView()
                        .frame(width: side, height: side)
                        .background(.secondary.opacity(0.1), in: .rect(cornerRadius: 12))
                        .accessibilityLabel(Text("Preparing photo"))
                }
            }
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
        // Миниатюры не растут бесконечно с Dynamic Type — поле ввода важнее.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

/// Микрофон → (подготовка) → «Done». Нейтральная, без фона: главная кнопка — «Send».
private struct DictationButton: View {
    let state: DictationViewModel.State
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 34

    var body: some View {
        Group {
            switch state {
            case .preparing, .downloading:
                // Нажатие во время подготовки — отмена.
                Button(action: action) {
                    ProgressView()
                        .frame(width: size, height: size)
                }
                .accessibilityLabel(Text("Cancel dictation"))
            case .recording:
                Button("Done", systemImage: "checkmark", action: action)
                    .labelStyle(.iconOnly)
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.appAccent)
                    .frame(width: size, height: size)
                    .background(.appAccent.opacity(0.15), in: .circle)
            case .idle, .unavailable, .failed:
                Button("Dictate", systemImage: "mic", action: action)
                    .labelStyle(.iconOnly)
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .contentShape(.circle)
        .contentTransition(.symbolEffect(.replace))
    }
}

/// Слева от кнопок: «Listening…» с уровнем громкости или прогресс загрузки модели.
private struct DictationStatus: View {
    let state: DictationViewModel.State
    let level: Float

    var body: some View {
        switch state {
        case .recording:
            Label {
                Text("Listening…")
            } icon: {
                // Уровень громкости — заливкой символа, без анимаций (дружит с Reduce Motion).
                Image(systemName: "waveform", variableValue: Double(level))
            }
            .textStyle(.caption)
            .foregroundStyle(.appAccent)
            .accessibilityLabel(Text("Listening"))
        case let .downloading(fraction):
            Text("Downloading speech model… \(Int((fraction * 100).rounded()))%")
                .textStyle(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .idle, .preparing, .unavailable, .failed:
            EmptyView()
        }
    }
}

/// Почему диктовка не началась: текст, «Open Settings» (если дело в разрешении), «Dismiss».
private struct DictationMessage: View {
    let presentation: DictationMessagePresentation
    let dictation: ComposerDictation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(presentation.title)
                    .foregroundStyle(.primary)
                if dictation.canOpenSettings {
                    Button("Open Settings", action: dictation.openSettings)
                        .foregroundStyle(.appAccent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark", action: dictation.dismissMessage)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(.rect)
        }
        .textStyle(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.appSurface, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary.opacity(0.25)) }
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
            ComposerView(text: $filled, isGenerating: false, canSend: true,
                         dictation: ComposerDictation(state: .recording, level: 0.6), onSend: {}, onStop: {})
            ComposerView(text: $empty, isGenerating: false, canSend: true, dictation: ComposerDictation(),
                         attachments: ComposerAttachments(isPreparing: true), onSend: {}, onStop: {})
            ComposerView(text: $empty, isGenerating: false, canSend: false,
                         dictation: ComposerDictation(state: .unavailable(.microphoneDenied), canOpenSettings: true),
                         onSend: {}, onStop: {})
        }
        .background(.appBackground)
    }
}

#Preview("Light") { ComposerPreview() }
#Preview("Dark") { ComposerPreview().preferredColorScheme(.dark) }
#endif
