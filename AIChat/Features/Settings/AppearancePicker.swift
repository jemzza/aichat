import SwiftUI

/// Три карточки темы с мини-превью интерфейса. Выбранная — обводка и подпись цветом `Accent`.
struct AppearancePicker: View {
    @Binding var selection: AppearancePreference

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(AppearancePreference.allCases, id: \.self) { option in
                AppearanceOption(appearance: option, isSelected: option == selection) {
                    selection = option
                }
            }
        }
    }
}

extension AppearancePreference {
    var title: LocalizedStringKey {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }
}

private struct AppearanceOption: View {
    let appearance: AppearancePreference
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AppearanceThumbnail(appearance: appearance)
                    .aspectRatio(0.72, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isSelected ? Color.appAccent : Color.secondary.opacity(0.3),
                                          lineWidth: isSelected ? 2 : 1)
                    }
                Text(appearance.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.appAccent : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Мини-превью: та же палитра из Assets, принудительно в светлом или тёмном варианте.
/// У System — светлая половина и тёмная, разделённые по диагонали.
private struct AppearanceThumbnail: View {
    let appearance: AppearancePreference

    var body: some View {
        Group {
            switch appearance {
            case .light:
                MiniInterface().environment(\.colorScheme, .light)
            case .dark:
                MiniInterface().environment(\.colorScheme, .dark)
            case .system:
                MiniInterface()
                    .environment(\.colorScheme, .light)
                    .overlay {
                        MiniInterface()
                            .environment(\.colorScheme, .dark)
                            .clipShape(LowerTrailingTriangle())
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Схематичный экран чата: верхняя панель, вопрос, строки ответа, поле ввода.
private struct MiniInterface: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let unit = width / 10
            VStack(alignment: .leading, spacing: unit * 0.6) {
                HStack {
                    Capsule().frame(width: unit * 1.4, height: unit * 0.35)
                    Spacer(minLength: 0)
                    Circle().frame(width: unit * 0.7, height: unit * 0.7)
                }
                .foregroundStyle(Color.secondary.opacity(0.6))

                RoundedRectangle(cornerRadius: unit * 0.45)
                    .fill(.appSurface)
                    .frame(width: width * 0.5, height: unit * 1.3)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                VStack(alignment: .leading, spacing: unit * 0.35) {
                    ForEach([0.85, 0.7, 0.78, 0.45], id: \.self) { fraction in
                        Capsule()
                            .fill(Color.primary.opacity(0.22))
                            .frame(width: width * fraction * 0.84, height: unit * 0.32)
                    }
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer(minLength: 0)
                    Circle()
                        .fill(.appAccent)
                        .frame(width: unit * 0.9, height: unit * 0.9)
                }
                .padding(unit * 0.25)
                .background(.appSurface, in: .capsule)
            }
            .padding(unit * 0.8)
            .frame(width: width, height: proxy.size.height, alignment: .top)
            .background(.appBackground)
        }
    }
}

/// Нижний правый треугольник прямоугольника — тёмная половина превью System.
private struct LowerTrailingTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

#if DEBUG
private struct AppearancePickerPreview: View {
    @State private var selection = AppearancePreference.system

    var body: some View {
        AppearancePicker(selection: $selection)
            .padding()
            .background(.appSurface, in: .rect(cornerRadius: 16))
            .padding()
            .frame(maxHeight: .infinity)
            .background(.appBackground)
    }
}

#Preview("Light") { AppearancePickerPreview() }
#Preview("Dark") { AppearancePickerPreview().preferredColorScheme(.dark) }
#endif
