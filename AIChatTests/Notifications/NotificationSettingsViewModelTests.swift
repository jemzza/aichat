import Foundation
import Testing
@testable import AIChat

@MainActor
struct NotificationSettingsViewModelTests {
    private func make(_ status: NotificationAuthorization, grants: Bool = true,
                      settings: InMemorySettingsStore = InMemorySettingsStore())
        -> (NotificationSettingsViewModel, FakeNotificationScheduler, InMemorySettingsStore) {
        let scheduler = FakeNotificationScheduler(status: status, grantsOnRequest: grants)
        return (NotificationSettingsViewModel(settings: settings, scheduler: scheduler), scheduler, settings)
    }

    @Test func openingTheScreenDoesNotAskForPermission() async {
        let (viewModel, scheduler, _) = make(.notDetermined)

        await viewModel.refresh()

        #expect(scheduler.requestCount == 0)
        #expect(viewModel.areTogglesEnabled)
        #expect(viewModel.isOn(.replies) == false)
    }

    @Test func firstEnableAsksOnceAndStoresTheAnswer() async {
        let (viewModel, scheduler, settings) = make(.notDetermined)
        await viewModel.refresh()

        await viewModel.setEnabled(.replies, true)
        await viewModel.setEnabled(.queuedSent, true)

        #expect(scheduler.requestCount == 1)
        #expect(settings.notifyOnReply && settings.notifyOnQueuedSent)
        #expect(viewModel.isOn(.replies) && viewModel.isOn(.queuedSent))
    }

    @Test func declinedRequestKeepsToggleOffAndShowsNotice() async {
        let (viewModel, scheduler, settings) = make(.notDetermined, grants: false)
        await viewModel.refresh()

        await viewModel.setEnabled(.replies, true)

        #expect(scheduler.requestCount == 1)
        #expect(settings.notifyOnReply == false)
        #expect(viewModel.isOn(.replies) == false)
        #expect(viewModel.isDeniedInSystem)
        #expect(viewModel.areTogglesEnabled == false)
    }

    @Test func deniedInSystemShowsTogglesOffEvenIfStoredOn() async {
        let (viewModel, scheduler, settings) = make(.denied, settings: InMemorySettingsStore(notifyOnReply: true))
        await viewModel.refresh()

        #expect(viewModel.isOn(.replies) == false)
        #expect(viewModel.isDeniedInSystem)

        await viewModel.setEnabled(.replies, true)
        #expect(scheduler.requestCount == 0)

        // Разрешили в системных Настройках — сохранённое значение снова видно.
        scheduler.status = .authorized
        await viewModel.refresh()
        #expect(viewModel.isOn(.replies))
        #expect(settings.notifyOnReply)
    }

    @Test func disablingNeverAsks() async {
        let (viewModel, scheduler, settings) = make(.authorized, settings: InMemorySettingsStore(notifyOnReply: true))
        await viewModel.refresh()

        await viewModel.setEnabled(.replies, false)

        #expect(settings.notifyOnReply == false)
        #expect(scheduler.requestCount == 0)
    }
}
