import SwiftUI

/// Выезжающая слева панель для iPhone: основной экран сдвигается вправо и
/// затемняется. Открывается кнопкой (через `isOpen`) или свайпом от левого края,
/// закрывается свайпом влево или нажатием на затемнённый экран.
struct SideDrawer<Drawer: View, Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder var drawer: Drawer
    @ViewBuilder var content: Content

    private enum DragState: Equatable {
        case idle
        case tracking(CGFloat)
        /// Жест не наш (вертикальный скролл или не от края) — до конца жеста не вмешиваемся.
        case rejected

        var translation: CGFloat {
            if case let .tracking(value) = self { value } else { 0 }
        }
    }

    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var drag = DragState.idle

    /// Зона у левого края, откуда свайп открывает панель.
    private let edgeWidth: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.85, 360)
            let offset = min(max((isOpen ? width : 0) + drag.translation, 0), width)
            let progress = offset / width

            ZStack(alignment: .leading) {
                drawer
                    .frame(width: width)
                    .offset(x: (offset - width) * 0.3)
                    // Закрытая панель лежит под экраном и не должна ловить нажатия.
                    .allowsHitTesting(isOpen)
                    .accessibilityHidden(!isOpen)

                content
                    .frame(width: proxy.size.width)
                    .contentShape(.rect)
                    .overlay { scrim(progress: progress) }
                    .offset(x: offset)
                    .accessibilityHidden(isOpen)
            }
            .simultaneousGesture(dragGesture(width: width))
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isOpen)
    }

    private func scrim(progress: CGFloat) -> some View {
        // Затемнение — системный чёрный с прозрачностью: одинаково в обеих темах.
        Color.black
            .opacity(0.3 * progress)
            .ignoresSafeArea()
            .contentShape(.rect)
            .allowsHitTesting(isOpen)
            .onTapGesture { close() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text("Close sidebar"))
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($drag) { value, state, _ in
                if state == .idle {
                    state = accepts(value) ? .tracking(0) : .rejected
                }
                if case .tracking = state {
                    state = .tracking(value.translation.width)
                }
            }
            .onEnded { value in
                guard accepts(value) else { return }
                let projected = (isOpen ? width : 0) + value.predictedEndTranslation.width
                withAnimation(.snappy) { isOpen = projected > width / 2 }
            }
    }

    /// Горизонтальный жест: закрытая панель — только от левого края, открытая — откуда угодно.
    private func accepts(_ value: DragGesture.Value) -> Bool {
        let isHorizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
        return isHorizontal && (isOpen || value.startLocation.x <= edgeWidth)
    }

    private func close() {
        withAnimation(.snappy) { isOpen = false }
    }
}
