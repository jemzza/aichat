import SwiftUI

/// Подэкран Notifications: «Replies» и «Queued messages sent».
struct NotificationSettingsView: View {
    @State private var viewModel: NotificationSettingsViewModel
    private let openAppSettings: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    init(viewModel: NotificationSettingsViewModel, openAppSettings: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.openAppSettings = openAppSettings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsSection {
                    ToggleRow(title: "Replies",
                              subtitle: "Get notified when a reply finishes.",
                              isOn: binding(.replies))
                    SettingsDivider()
                    ToggleRow(title: "Queued messages sent",
                              subtitle: "Get notified when messages waiting for a connection are sent.",
                              isOn: binding(.queuedSent))
                }
                .disabled(!viewModel.areTogglesEnabled)

                if viewModel.isDeniedInSystem {
                    deniedNotice
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.appBackground)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await viewModel.refresh() } }
        }
    }

    private var deniedNotice: some View {
        SettingsSection("Notifications are turned off in Settings") {
            Button(action: openAppSettings) {
                SettingsRowLabel(title: "Open Settings", systemImage: "gear", accessory: .external)
            }
            .buttonStyle(.plain)
        }
    }

    private func binding(_ kind: NotificationSettingsViewModel.Kind) -> Binding<Bool> {
        let viewModel = viewModel
        return Binding {
            viewModel.isOn(kind)
        } set: { isOn in
            Task { await viewModel.setEnabled(kind, isOn) }
        }
    }
}

/// Переключатель с подзаголовком под названием.
private struct ToggleRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(.appAccent)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#if DEBUG
@MainActor
private func notificationsPreview(_ status: NotificationAuthorization) -> some View {
    NavigationStack {
        NotificationSettingsView(
            viewModel: NotificationSettingsViewModel(
                settings: InMemorySettingsStore(notifyOnReply: true),
                scheduler: FakeNotificationScheduler(status: status)
            ),
            openAppSettings: {}
        )
    }
}

#Preview("Light") { notificationsPreview(.authorized) }
#Preview("Dark") { notificationsPreview(.authorized).preferredColorScheme(.dark) }
#Preview("Denied") { notificationsPreview(.denied) }
#endif
