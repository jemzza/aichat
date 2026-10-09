import Foundation
import Testing
@testable import AIChat

@MainActor
struct PrivacyViewModelTests {
    private func makeSession() throws -> (PreviewChatSession, InMemoryChatRepository) {
        let repository = PreviewData.repositoryWithFolders()
        return (PreviewChatSession(repository: repository), repository)
    }

    @Test func showsStatusOfEveryPermissionAndRefreshes() throws {
        let (session, _) = try makeSession()
        let permissions = FakePermissionStatus([.microphone: .denied, .speechRecognition: .notDetermined])
        let viewModel = PrivacyViewModel(session: session, permissions: permissions)

        #expect(viewModel.permissions.map(\.permission) == [.microphone, .speechRecognition])
        #expect(viewModel.permissions.map(\.status) == [.denied, .notDetermined])

        permissions.statuses = [.microphone: .granted, .speechRecognition: .restricted]
        viewModel.refreshPermissions()
        #expect(viewModel.permissions.map(\.status) == [.granted, .restricted])
    }

    @Test func confirmedDeleteAllEmptiesRepositoryAndClosesSettings() async throws {
        let (session, repository) = try makeSession()
        var closed = 0
        let viewModel = PrivacyViewModel(session: session, permissions: FakePermissionStatus(),
                                         onDeletedAll: { closed += 1 })

        viewModel.requestDeleteAll()
        #expect(viewModel.isConfirmingDeleteAll)
        await viewModel.confirmDeleteAll()?.value

        #expect(viewModel.isConfirmingDeleteAll == false)
        #expect(viewModel.isDeleting == false)
        #expect(viewModel.deleteFailed == false)
        #expect(closed == 1)
        let snapshot = try await firstValue(of: repository.observeSidebar())
        #expect(snapshot.folders.isEmpty && snapshot.recents.isEmpty)
    }

    @Test func secondConfirmationWhileDeletingIsIgnored() async throws {
        let (session, _) = try makeSession()
        var closed = 0
        let viewModel = PrivacyViewModel(session: session, permissions: FakePermissionStatus(),
                                         onDeletedAll: { closed += 1 })

        let task = viewModel.confirmDeleteAll()
        #expect(viewModel.confirmDeleteAll() == nil)
        await task?.value
        #expect(closed == 1)
    }
}
