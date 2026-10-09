import SwiftUI

/// Секция настроек: мелкий заголовок и карточка со скруглёнными углами.
struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey?
    let footer: LocalizedStringKey?
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                content
            }
            .background(.appSurface, in: .rect(cornerRadius: 16))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// Разделитель строк внутри карточки — с отступом под иконку.
struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 54)
    }
}

/// Строка: иконка, название, справа — значение и/или признак перехода.
struct SettingsRowLabel: View {
    enum Accessory {
        case none
        /// Переход на подэкран.
        case chevron
        /// Уводит из приложения (ссылка, системные Настройки).
        case external
    }

    let title: LocalizedStringKey
    let systemImage: String
    var value: LocalizedStringKey?
    var accessory = Accessory.chevron
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
            }
            switch accessory {
            case .none:
                EmptyView()
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            case .external:
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(.rect)
    }
}

/// Круглая кнопка ✕ в шапке. На iOS 26 круг (Liquid Glass) рисует сама панель.
struct SettingsCloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            Button("Close", systemImage: "xmark", action: action)
        } else {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(.appSurface, in: .circle)
            }
            // Иначе панель красит кнопку в акцент — на iOS 26 ✕ основного цвета.
            .tint(.primary)
            .accessibilityLabel(Text("Close"))
        }
    }
}
