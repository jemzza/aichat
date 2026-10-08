import Foundation
import Observation

/// Группа «Recents» по дате последнего сообщения.
enum ChatDateGroup: CaseIterable, Hashable, Sendable {
    case today
    case yesterday
    case previous7Days
    case older

    var title: LocalizedStringResource {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .previous7Days: "Previous 7 days"
        case .older: "Older"
        }
    }

    static func group(for date: Date, now: Date, calendar: Calendar) -> ChatDateGroup {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .yesterday
        case 2...7: return .previous7Days
        default: return .older
        }
    }
}

struct ChatSection: Identifiable, Hashable, Sendable {
    let group: ChatDateGroup
    let chats: [Chat]

    var id: ChatDateGroup { group }
}

/// Сайдбар: список чатов из репозитория, поиск, выбор, переименование и удаление.
/// Выбранный чат (`nil` — «New chat», черновик) хранится здесь же: его читают
/// и сайдбар, и верхняя панель чата.
@MainActor
@Observable
final class ChatListViewModel {
    private(set) var chats: [Chat] = []
    /// Пока не пришло первое значение из базы, пустое состояние не показываем.
    private(set) var hasLoaded = false
    var searchText = ""
    var selectedChatId: UUID?

    /// Чат, который сейчас переименовывают (алерт с полем ввода).
    private(set) var renamingChat: Chat?
    var renameText = ""
    /// Чат, удаление которого ждёт подтверждения.
    var chatPendingDeletion: Chat?
    private(set) var actionFailed = false

    @ObservationIgnored private let repository: any ChatRepository
    @ObservationIgnored private let session: any ChatSession
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar

    init(
        repository: any ChatRepository,
        session: any ChatSession,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.repository = repository
        self.session = session
        self.now = now
        self.calendar = calendar
    }

    var selectedChat: Chat? {
        selectedChatId.flatMap { id in chats.first { $0.id == id } }
    }

    /// Чаты, подходящие под поиск, сгруппированные по дате; пустые группы опущены.
    var sections: [ChatSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = query.isEmpty ? chats : chats.filter { $0.title.localizedStandardContains(query) }
        let date = now()
        let grouped = Dictionary(grouping: visible) {
            ChatDateGroup.group(for: $0.updatedAt, now: date, calendar: calendar)
        }
        return ChatDateGroup.allCases.compactMap { group in
            grouped[group].map { ChatSection(group: group, chats: $0) }
        }
    }

    var isEmpty: Bool { hasLoaded && chats.isEmpty }
    var hasNoSearchResults: Bool { !chats.isEmpty && sections.isEmpty }

    /// Подписка на базу; живёт, пока жива задача вызывающего (`.task` во View).
    func observe() async {
        for await chats in repository.observeChats() {
            self.chats = chats
            hasLoaded = true
            if let selectedChatId, !chats.contains(where: { $0.id == selectedChatId }) {
                self.selectedChatId = nil
            }
        }
    }

    func startNewChat() {
        selectedChatId = nil
        searchText = ""
    }

    func select(_ chat: Chat) {
        selectedChatId = chat.id
    }

    // MARK: Переименование

    func beginRename(_ chat: Chat) {
        renamingChat = chat
        renameText = chat.title
    }

    func cancelRename() {
        renamingChat = nil
    }

    var canCommitRename: Bool {
        !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func commitRename() async {
        guard let chat = renamingChat else { return }
        renamingChat = nil
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != chat.title else { return }
        do {
            try await repository.renameChat(id: chat.id, title: title)
        } catch {
            actionFailed = true
        }
    }

    // MARK: Удаление

    func requestDelete(_ chat: Chat) {
        chatPendingDeletion = chat
    }

    func confirmDelete() async {
        guard let chat = chatPendingDeletion else { return }
        chatPendingDeletion = nil
        if selectedChatId == chat.id { selectedChatId = nil }
        do {
            try await session.deleteChat(id: chat.id)
        } catch {
            actionFailed = true
        }
    }

    func dismissActionFailure() {
        actionFailed = false
    }
}
