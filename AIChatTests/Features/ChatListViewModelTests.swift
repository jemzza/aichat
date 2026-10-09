import Foundation
import Testing
@testable import AIChat

@MainActor
struct ChatListViewModelTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 12:00 UTC — «0,4 дня назад» остаётся в том же дне.
    private static let now = Date(timeIntervalSince1970: 1_791_288_000)

    private static func chat(_ title: String, daysAgo: Double) -> Chat {
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        return Chat(id: UUID(), title: title, createdAt: date, updatedAt: date)
    }

    private static func message(in chat: Chat) -> Message {
        Message(chatId: chat.id, role: .user, text: "Hi", status: .sent, createdAt: chat.updatedAt)
    }

    private static func folder(_ name: String, position: Int) -> Folder {
        Folder(id: UUID(), name: name, position: position, createdAt: now)
    }

    private static func chat(_ title: String, daysAgo: Double, in folder: Folder) -> Chat {
        var chat = chat(title, daysAgo: daysAgo)
        chat.folderId = folder.id
        return chat
    }

    private func makeViewModel(
        folders: [Folder] = [],
        chats: [Chat]
    ) async throws -> (ChatListViewModel, InMemoryChatRepository, Task<Void, Never>) {
        let repository = InMemoryChatRepository(folders: folders, chats: chats, messages: chats.map(Self.message(in:)))
        let viewModel = ChatListViewModel(
            repository: repository,
            session: PreviewChatSession(repository: repository),
            now: { Self.now },
            calendar: Self.calendar
        )
        let observation = Task { await viewModel.observe() }
        try await waitUntil { viewModel.hasLoaded }
        return (viewModel, repository, observation)
    }

    @Test(arguments: [
        (0.0, ChatDateGroup.today),
        (0.4, .today),
        (1.0, .yesterday),
        (2.0, .previous7Days),
        (7.0, .previous7Days),
        (8.0, .older),
        (400.0, .older),
    ])
    func groupsByCalendarDay(daysAgo: Double, expected: ChatDateGroup) {
        let date = Self.now.addingTimeInterval(-daysAgo * 86_400)
        #expect(ChatDateGroup.group(for: date, now: Self.now, calendar: Self.calendar) == expected)
    }

    @Test func sectionsSkipEmptyGroupsAndKeepOrder() async throws {
        let (viewModel, _, observation) = try await makeViewModel(chats: [
            Self.chat("Old", daysAgo: 30), Self.chat("Fresh", daysAgo: 0), Self.chat("Last week", daysAgo: 3),
        ])
        defer { observation.cancel() }

        #expect(viewModel.sections.map(\.group) == [.today, .previous7Days, .older])
        #expect(viewModel.sections.map { $0.chats.map(\.title) } == [["Fresh"], ["Last week"], ["Old"]])
    }

    @Test func openChatFromNotificationSelectsExistingChatOnly() async throws {
        let target = Self.chat("Target", daysAgo: 1)
        let (viewModel, _, observation) = try await makeViewModel(chats: [Self.chat("Other", daysAgo: 0), target])
        defer { observation.cancel() }
        viewModel.searchText = "oth"

        viewModel.openChat(id: target.id)
        #expect(viewModel.selectedChatId == target.id)
        #expect(viewModel.searchText.isEmpty)

        viewModel.openChat(id: UUID())
        #expect(viewModel.selectedChatId == target.id)
    }

    @Test func searchFiltersByTitleIgnoringCase() async throws {
        let (viewModel, _, observation) = try await makeViewModel(chats: [
            Self.chat("Swift actors", daysAgo: 0), Self.chat("Trip ideas", daysAgo: 1),
        ])
        defer { observation.cancel() }

        viewModel.searchText = "  SWIFT "
        #expect(viewModel.sections.flatMap(\.chats).map(\.title) == ["Swift actors"])

        viewModel.searchText = "nothing"
        #expect(viewModel.hasNoSearchResults)
        #expect(!viewModel.isEmpty)
    }

    @Test func emptyStateOnlyAfterFirstLoad() async throws {
        let repository = InMemoryChatRepository()
        let viewModel = ChatListViewModel(repository: repository, session: PreviewChatSession(repository: repository))
        #expect(!viewModel.isEmpty)

        let observation = Task { await viewModel.observe() }
        defer { observation.cancel() }
        try await waitUntil { viewModel.hasLoaded }
        #expect(viewModel.isEmpty)
    }

    @Test func renameTrimsTitleAndIgnoresBlank() async throws {
        let chat = Self.chat("Old title", daysAgo: 0)
        let (viewModel, _, observation) = try await makeViewModel(chats: [chat])
        defer { observation.cancel() }

        viewModel.beginRename(chat)
        viewModel.renameText = "   "
        #expect(!viewModel.canCommitRename)
        await viewModel.commitRename()?.value
        #expect(viewModel.renamingChat == nil)
        #expect(viewModel.chats.first?.title == "Old title")

        viewModel.beginRename(chat)
        viewModel.renameText = "  New title \n"
        await viewModel.commitRename()?.value
        try await waitUntil { viewModel.chats.first?.title == "New title" }
    }

    @Test func deleteSelectedChatFallsBackToNewChat() async throws {
        let first = Self.chat("First", daysAgo: 0)
        let second = Self.chat("Second", daysAgo: 1)
        let (viewModel, _, observation) = try await makeViewModel(chats: [first, second])
        defer { observation.cancel() }

        viewModel.select(first)
        viewModel.requestDelete(first)
        await viewModel.confirmDelete()?.value

        #expect(viewModel.selectedChatId == nil)
        try await waitUntil { viewModel.chats.map(\.id) == [second.id] }
        #expect(!viewModel.actionFailed)
    }

    @Test func selectionResetsWhenChatDisappears() async throws {
        let chat = Self.chat("Doomed", daysAgo: 0)
        let (viewModel, repository, observation) = try await makeViewModel(chats: [chat])
        defer { observation.cancel() }

        viewModel.select(chat)
        repository.deleteChat(id: chat.id)

        try await waitUntil { viewModel.selectedChatId == nil }
    }

    @Test func createdChatKeepsScreenButSelectingAnotherReplacesIt() async throws {
        let existing = Self.chat("Existing", daysAgo: 0)
        let (viewModel, _, observation) = try await makeViewModel(chats: [existing])
        defer { observation.cancel() }

        let newChatScreen = viewModel.screenID
        viewModel.didCreateChat(id: UUID())
        #expect(viewModel.screenID == newChatScreen)

        viewModel.select(existing)
        #expect(viewModel.screenID != newChatScreen)

        let existingScreen = viewModel.screenID
        viewModel.select(existing)
        #expect(viewModel.screenID == existingScreen)
    }

    /// Свежесозданный чат может ещё не попасть в снимок списка — выбор не сбрасываем.
    @Test func createdChatNotYetListedStaysSelected() async throws {
        let (viewModel, repository, observation) = try await makeViewModel(chats: [Self.chat("Other", daysAgo: 0)])
        defer { observation.cancel() }

        let id = UUID()
        viewModel.didCreateChat(id: id)
        try repository.renameChat(id: viewModel.chats[0].id, title: "Renamed")
        try await waitUntil { viewModel.chats.first?.title == "Renamed" }

        #expect(viewModel.selectedChatId == id)
    }

    // MARK: Папки

    @Test func chatsInFoldersAreNotInRecents() async throws {
        let work = Self.folder("Work", position: 0)
        let inFolder = Self.chat("Report", daysAgo: 0, in: work)
        let loose = Self.chat("Loose", daysAgo: 1)
        let (viewModel, _, observation) = try await makeViewModel(folders: [work], chats: [inFolder, loose])
        defer { observation.cancel() }

        #expect(viewModel.sections.flatMap(\.chats).map(\.id) == [loose.id])
        #expect(viewModel.folderSections.map(\.folder.id) == [work.id])
        #expect(viewModel.folderSections.first?.chats.map(\.id) == [inFolder.id])
        #expect(viewModel.folderSections.first?.isExpanded == true)
        #expect(Set(viewModel.chats.map(\.id)) == [inFolder.id, loose.id])
        #expect(!viewModel.hasNoSearchResults)
    }

    @Test func emptyFolderAloneIsNotEmptyState() async throws {
        let (viewModel, _, observation) = try await makeViewModel(folders: [Self.folder("Ideas", position: 0)], chats: [])
        defer { observation.cancel() }

        #expect(!viewModel.isEmpty)
        #expect(viewModel.folderSections.first?.totalCount == 0)
    }

    @Test func searchHidesFoldersWithoutMatchesAndExpandsTheRest() async throws {
        let work = Self.folder("Work", position: 0)
        let travel = Self.folder("Travel", position: 1)
        let (viewModel, _, observation) = try await makeViewModel(folders: [work, travel], chats: [
            Self.chat("Swift actors", daysAgo: 0, in: work),
            Self.chat("Budget", daysAgo: 0, in: work),
            Self.chat("Lisbon", daysAgo: 0, in: travel),
            Self.chat("Swift macros", daysAgo: 1),
        ])
        defer { observation.cancel() }
        viewModel.toggleExpanded(work)
        #expect(viewModel.folderSections.first?.isExpanded == false)

        viewModel.searchText = "swift"

        #expect(viewModel.folderSections.map(\.folder.id) == [work.id])
        #expect(viewModel.folderSections.first?.chats.map(\.title) == ["Swift actors"])
        #expect(viewModel.folderSections.first?.totalCount == 2)
        #expect(viewModel.folderSections.first?.isExpanded == true)
        #expect(viewModel.sections.flatMap(\.chats).map(\.title) == ["Swift macros"])

        viewModel.searchText = "nothing"
        #expect(viewModel.hasNoSearchResults)
    }

    @Test func dropMovesKnownChatIntoFolderAndBack() async throws {
        let work = Self.folder("Work", position: 0)
        let chat = Self.chat("Report", daysAgo: 0)
        let (viewModel, _, observation) = try await makeViewModel(folders: [work], chats: [chat])
        defer { observation.cancel() }
        viewModel.select(chat)
        viewModel.toggleExpanded(work)

        #expect(viewModel.dropChats([chat.id], into: work.id))
        try await waitUntil { viewModel.folderSections.first?.chats.map(\.id) == [chat.id] }
        #expect(viewModel.sections.isEmpty)
        // Свёрнутая папка раскрывается, чтобы было видно, куда упал чат.
        #expect(viewModel.folderSections.first?.isExpanded == true)
        #expect(viewModel.selectedChatId == chat.id)

        // Повторный дроп в ту же папку — переносить нечего.
        #expect(!viewModel.dropChats([chat.id], into: work.id))

        #expect(viewModel.dropChats([chat.id], into: nil))
        try await waitUntil { viewModel.sections.flatMap(\.chats).map(\.id) == [chat.id] }
        #expect(viewModel.folderSections.first?.chats.isEmpty == true)
        #expect(!viewModel.actionFailed)
    }

    @Test func dropWithUnknownChatOrFolderIsIgnored() async throws {
        let work = Self.folder("Work", position: 0)
        let chat = Self.chat("Report", daysAgo: 0)
        let (viewModel, repository, observation) = try await makeViewModel(folders: [work], chats: [chat])
        defer { observation.cancel() }

        #expect(!viewModel.dropChats([UUID()], into: work.id))
        #expect(!viewModel.dropChats([chat.id], into: UUID()))
        #expect(!viewModel.dropChats([], into: work.id))

        // Папку удалили, а снимок во ViewModel ещё не обновился.
        repository.deleteFolder(id: work.id)
        try await waitUntil { viewModel.folderSections.isEmpty }
        #expect(!viewModel.dropChats([chat.id], into: work.id))

        // Неизвестные id в смешанном дропе отбрасываются, известные переносятся.
        let travel = Self.folder("Travel", position: 0)
        repository.createFolder(id: travel.id, name: travel.name, createdAt: travel.createdAt)
        try await waitUntil { viewModel.folderSections.count == 1 }
        #expect(viewModel.dropChats([UUID(), chat.id, chat.id], into: travel.id))
        try await waitUntil { viewModel.folderSections.first?.chats.map(\.id) == [chat.id] }
        #expect(!viewModel.actionFailed)
    }

    @Test func dropRacingWithChatDeletionDoesNotAlert() async throws {
        let work = Self.folder("Work", position: 0)
        let chat = Self.chat("Report", daysAgo: 0)
        let (viewModel, repository, observation) = try await makeViewModel(folders: [work], chats: [chat])
        defer { observation.cancel() }

        // Снимок ещё содержит чат, а в хранилище его уже нет.
        repository.deleteChat(id: chat.id)
        #expect(viewModel.dropChats([chat.id], into: work.id))
        try await waitUntil { viewModel.chats.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!viewModel.actionFailed)
    }

    @Test func createAndRenameFolderTrimsNameAndRejectsBlank() async throws {
        let (viewModel, _, observation) = try await makeViewModel(chats: [])
        defer { observation.cancel() }

        viewModel.beginCreateFolder()
        viewModel.folderNameText = "  "
        #expect(!viewModel.canCommitFolderName)
        await viewModel.commitFolderName()?.value
        #expect(viewModel.folderNameEditing == nil)
        #expect(viewModel.folderSections.isEmpty)

        viewModel.beginCreateFolder()
        viewModel.folderNameText = " Work \n"
        await viewModel.commitFolderName()?.value
        try await waitUntil { viewModel.folderSections.map(\.folder.name) == ["Work"] }

        let folder = try #require(viewModel.folderSections.first?.folder)
        viewModel.beginRenameFolder(folder)
        #expect(viewModel.folderNameText == "Work")
        viewModel.folderNameText = "Projects"
        await viewModel.commitFolderName()?.value
        try await waitUntil { viewModel.folderSections.map(\.folder.name) == ["Projects"] }
        #expect(!viewModel.actionFailed)
    }

    @Test func deleteFolderMovesChatsToRecentsAndKeepsSelection() async throws {
        let work = Self.folder("Work", position: 0)
        let chat = Self.chat("Report", daysAgo: 0, in: work)
        let (viewModel, _, observation) = try await makeViewModel(folders: [work], chats: [chat])
        defer { observation.cancel() }
        viewModel.select(chat)

        viewModel.requestDeleteFolder(work)
        await viewModel.confirmDeleteFolder()?.value

        try await waitUntil { viewModel.folderSections.isEmpty }
        #expect(viewModel.folderPendingDeletion == nil)
        #expect(viewModel.sections.flatMap(\.chats).map(\.id) == [chat.id])
        #expect(viewModel.selectedChatId == chat.id)
        #expect(!viewModel.actionFailed)
    }

    @Test func moveFolderUpAndDownRespectsBounds() async throws {
        let a = Self.folder("A", position: 0)
        let b = Self.folder("B", position: 1)
        let c = Self.folder("C", position: 2)
        let (viewModel, _, observation) = try await makeViewModel(folders: [a, b, c], chats: [])
        defer { observation.cancel() }
        #expect(viewModel.folderSections.map(\.canMoveUp) == [false, true, true])
        #expect(viewModel.folderSections.map(\.canMoveDown) == [true, true, false])

        await viewModel.moveFolderUp(c)
        try await waitUntil { viewModel.folderSections.map(\.folder.name) == ["A", "C", "B"] }

        await viewModel.moveFolderDown(a)
        try await waitUntil { viewModel.folderSections.map(\.folder.name) == ["C", "A", "B"] }

        // За края — ничего не происходит.
        await viewModel.moveFolderUp(viewModel.folderSections[0].folder)
        await viewModel.moveFolderDown(viewModel.folderSections[2].folder)
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.folderSections.map(\.folder.name) == ["C", "A", "B"])
        #expect(!viewModel.actionFailed)
    }

    // MARK: Алерты

    /// Алерт, закрываясь, сбрасывает состояние через binding сразу после нажатия кнопки —
    /// раньше, чем начнётся запись. Подтверждение должно пережить этот сброс.
    @Test func confirmationsSurviveAlertDismissal() async throws {
        let chat = Self.chat("Old title", daysAgo: 0)
        let doomed = Self.chat("Doomed", daysAgo: 1)
        let work = Self.folder("Work", position: 0)
        let (viewModel, _, observation) = try await makeViewModel(folders: [work], chats: [chat, doomed])
        defer { observation.cancel() }

        viewModel.beginRename(chat)
        viewModel.renameText = "New title"
        let rename = viewModel.commitRename()
        viewModel.cancelRename()

        viewModel.requestDelete(doomed)
        let delete = viewModel.confirmDelete()
        viewModel.chatPendingDeletion = nil

        viewModel.beginCreateFolder()
        viewModel.folderNameText = "Travel"
        let create = viewModel.commitFolderName()
        viewModel.cancelFolderNameEditing()

        viewModel.requestDeleteFolder(work)
        let deleteFolder = viewModel.confirmDeleteFolder()
        viewModel.folderPendingDeletion = nil

        for task in [rename, delete, create, deleteFolder] { await task?.value }
        try await waitUntil {
            viewModel.chats.map(\.title) == ["New title"]
                && viewModel.folderSections.map(\.folder.name) == ["Travel"]
        }
        #expect(!viewModel.actionFailed)
    }
}
