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

    private func makeViewModel(chats: [Chat]) async throws -> (ChatListViewModel, InMemoryChatRepository, Task<Void, Never>) {
        let repository = InMemoryChatRepository(chats: chats, messages: chats.map(Self.message(in:)))
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
        await viewModel.commitRename()
        #expect(viewModel.renamingChat == nil)
        #expect(viewModel.chats.first?.title == "Old title")

        viewModel.beginRename(chat)
        viewModel.renameText = "  New title \n"
        await viewModel.commitRename()
        try await waitUntil { viewModel.chats.first?.title == "New title" }
    }

    @Test func deleteSelectedChatFallsBackToNewChat() async throws {
        let first = Self.chat("First", daysAgo: 0)
        let second = Self.chat("Second", daysAgo: 1)
        let (viewModel, _, observation) = try await makeViewModel(chats: [first, second])
        defer { observation.cancel() }

        viewModel.select(first)
        viewModel.requestDelete(first)
        await viewModel.confirmDelete()

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
}

