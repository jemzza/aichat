import SwiftUI

/// Настройки (sheet из сайдбара): «General» — переходы на подэкраны, «Appearance» — тема.
struct SettingsView: View {
    enum Destination: Hashable {
        case notifications
        case privacy
    }

    private let dependencies: ChatDependencies
    @Environment(\.dismiss) private var dismiss

    init(dependencies: ChatDependencies) {
        self.dependencies = dependencies
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    SettingsSection("General") {
                        NavigationLink(value: Destination.notifications) {
                            SettingsRowLabel(title: "Notifications", systemImage: "bell")
                        }
                        .buttonStyle(.plain)
                        SettingsDivider()
                        NavigationLink(value: Destination.privacy) {
                            SettingsRowLabel(title: "Privacy", systemImage: "hand.raised")
                        }
                        .buttonStyle(.plain)
                    }
                    SettingsSection("Appearance") {
                        AppearancePicker(selection: appearance)
                            .padding(16)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(.appBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SettingsCloseButton { dismiss() }
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .notifications:
                    NotificationSettingsView(
                        viewModel: NotificationSettingsViewModel(settings: dependencies.settings,
                                                                 scheduler: dependencies.notifications),
                        openAppSettings: dependencies.openAppSettings
                    )
                    .toolbarRole(.editor)
                case .privacy:
                    PrivacyView(viewModel: PrivacyViewModel(session: dependencies.session,
                                                            permissions: dependencies.permissions,
                                                            onDeletedAll: { dismiss() }),
                                openAppSettings: dependencies.openAppSettings)
                        // Назад — системная кнопка: на iOS 26 она круглая, а свайп «назад»
                        // и VoiceOver работают без своего кода. Без подписи — только шеврон.
                        .toolbarRole(.editor)
                }
            }
        }
    }

    private var appearance: Binding<AppearancePreference> {
        let settings = dependencies.settings
        return Binding { settings.appearance } set: { settings.appearance = $0 }
    }
}

#if DEBUG
#Preview("Light") { SettingsView(dependencies: .preview()) }
#Preview("Dark") { SettingsView(dependencies: .preview()).preferredColorScheme(.dark) }
#endif
