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

/// Папка в сайдбаре с чатами, которые сейчас видны (с учётом поиска).
struct FolderSectionItem: Identifiable, Hashable, Sendable {
    let folder: Folder
    let chats: [Chat]
    /// Сколько чатов в папке всего, без учёта поиска.
    let totalCount: Int
    let isExpanded: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool

    var id: UUID { folder.id }
}

/// Какое имя папки сейчас редактируют (алерт с полем ввода).
enum FolderNameEditing: Hashable, Sendable {
    case create
    case rename(Folder)
}

/// Сайдбар: папки и чаты из репозитория, поиск, выбор, переименование, удаление,
/// перенос чатов между папками.
/// Выбранный чат (`nil` — «New chat», черновик) хранится здесь же: его читают
/// и сайдбар, и верхняя панель чата.
@MainActor
@Observable
final class ChatListViewModel {
    /// Все чаты — и в папках, и в «Recents», новые сверху.
    private(set) var chats: [Chat] = []
    private(set) var snapshot = SidebarSnapshot.empty
    /// Свёрнутые папки. Только в памяти: после перезапуска все развёрнуты.
    private(set) var collapsedFolderIds: Set<UUID> = []
    /// Пока не пришло первое значение из базы, пустое состояние не показываем.
    private(set) var hasLoaded = false
    var searchText = ""
    private(set) var selectedChatId: UUID? {
        didSet { if !isAdoptingCreatedChat { screenID = UUID() } }
    }
    /// Идентичность экрана чата: меняется при выборе другого чата, но не когда
    /// новый чат получил id после первой отправки — экран не пересоздаётся.
    private(set) var screenID = UUID()
    @ObservationIgnored private var isAdoptingCreatedChat = false

    /// Чат, который сейчас переименовывают (алерт с полем ввода).
    private(set) var renamingChat: Chat?
    var renameText = ""
    /// Чат, удаление которого ждёт подтверждения.
    var chatPendingDeletion: Chat?
    private(set) var folderNameEditing: FolderNameEditing?
    var folderNameText = ""
    /// Папка, удаление которой ждёт подтверждения.
    var folderPendingDeletion: Folder?
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

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearching: Bool { !query.isEmpty }

    private func matchesSearch(_ chat: Chat) -> Bool {
        query.isEmpty || chat.title.localizedStandardContains(query)
    }

    /// Чаты без папки («Recents»), подходящие под поиск, сгруппированные по дате;
    /// пустые группы опущены.
    var sections: [ChatSection] {
        let visible = snapshot.recents.filter(matchesSearch)
        let date = now()
        let grouped = Dictionary(grouping: visible) {
            ChatDateGroup.group(for: $0.updatedAt, now: date, calendar: calendar)
        }
        return ChatDateGroup.allCases.compactMap { group in
            grouped[group].map { ChatSection(group: group, chats: $0) }
        }
    }

    /// Папки по порядку. При поиске — только папки с совпадениями, развёрнутые.
    var folderSections: [FolderSectionItem] {
        let folders = snapshot.folders
        return folders.enumerated().compactMap { index, section in
            let visible = section.chats.filter(matchesSearch)
            if isSearching && visible.isEmpty { return nil }
            return FolderSectionItem(
                folder: section.folder,
                chats: visible,
                totalCount: section.chats.count,
                isExpanded: isSearching || !collapsedFolderIds.contains(section.folder.id),
                canMoveUp: index > 0,
                canMoveDown: index < folders.count - 1
            )
        }
    }

    /// Папки, в которые можно перенести чат из меню «Move to folder».
    var folders: [Folder] { snapshot.folders.map(\.folder) }

    var isEmpty: Bool { hasLoaded && chats.isEmpty && snapshot.folders.isEmpty }
    var hasNoSearchResults: Bool { isSearching && sections.isEmpty && folderSections.isEmpty }

    /// Подписка на базу; живёт, пока жива задача вызывающего (`.task` во View).
    func observe() async {
        for await snapshot in repository.observeSidebar() {
            let wasListed = selectedChatId.map { id in self.chats.contains { $0.id == id } } ?? false
            let chats = (snapshot.folders.flatMap(\.chats) + snapshot.recents)
                .sorted { ($0.updatedAt, $0.createdAt) > ($1.updatedAt, $1.createdAt) }
            self.snapshot = snapshot
            self.chats = chats
            collapsedFolderIds.formIntersection(snapshot.folders.map(\.folder.id))
            hasLoaded = true
            // Сбрасываем выбор, только если чат был в списке и исчез (удалён). Только что
            // созданный чат может ещё не дойти до списка — его не трогаем.
            if wasListed, let selectedChatId, !chats.contains(where: { $0.id == selectedChatId }) {
                self.selectedChatId = nil
            }
        }
    }

    func startNewChat() {
        if selectedChatId != nil { selectedChatId = nil }
        searchText = ""
    }

    /// Нажатие на уведомление. Чат, которого уже нет в загруженном списке (удалён), не открываем.
    func openChat(id: UUID) {
        if hasLoaded, !chats.contains(where: { $0.id == id }) { return }
        searchText = ""
        if selectedChatId != id { selectedChatId = id }
    }

    func select(_ chat: Chat) {
        if selectedChatId != chat.id { selectedChatId = chat.id }
    }

    /// Новый чат сохранён вместе с первым сообщением — выделяем его в списке.
    func didCreateChat(id: UUID) {
        isAdoptingCreatedChat = true
        selectedChatId = id
        isAdoptingCreatedChat = false
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

    // Подтверждения из алертов (`commitRename`, `confirmDelete`, `commitFolderName`,
    // `confirmDeleteFolder`) синхронны: алерт, закрываясь, сразу сбрасывает состояние
    // через binding (`cancelRename` и т. п.), поэтому введённое забираем до записи,
    // а сама запись идёт в возвращаемой задаче (её ждут тесты).

    @discardableResult
    func commitRename() -> Task<Void, Never>? {
        guard let chat = renamingChat else { return nil }
        renamingChat = nil
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != chat.title else { return nil }
        return Task {
            do {
                try await repository.renameChat(id: chat.id, title: title)
            } catch {
                actionFailed = true
            }
        }
    }

    // MARK: Удаление

    func requestDelete(_ chat: Chat) {
        chatPendingDeletion = chat
    }

    @discardableResult
    func confirmDelete() -> Task<Void, Never>? {
        guard let chat = chatPendingDeletion else { return nil }
        chatPendingDeletion = nil
        if selectedChatId == chat.id { selectedChatId = nil }
        return Task {
            do {
                try await session.deleteChat(id: chat.id)
            } catch {
                actionFailed = true
            }
        }
    }

    // MARK: Перенос чатов

    /// Перенос чатов в папку (`nil` — в «Recents»): перетаскивание и «Move to folder».
    /// Синхронный — `.dropDestination` ждёт ответ сразу. Неизвестные id и уже лежащие
    /// в этой папке чаты отбрасываются; неизвестная (удалённая) папка — дроп не принят.
    /// - Returns: `false`, если переносить нечего.
    @discardableResult
    func dropChats(_ ids: [UUID], into folderId: UUID?) -> Bool {
        if let folderId, !snapshot.folders.contains(where: { $0.folder.id == folderId }) { return false }
        let known = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        let toMove = ids.filter { id in
            guard let chat = known[id], chat.folderId != folderId else { return false }
            return seen.insert(id).inserted
        }
        guard !toMove.isEmpty else { return false }
        // Показываем, куда упал чат.
        if let folderId { collapsedFolderIds.remove(folderId) }
        Task {
            for id in toMove {
                do {
                    try await repository.moveChat(id: id, toFolder: folderId)
                } catch is ChatNotFound {
                    // Чат удалили между дропом и записью — переносить нечего.
                } catch is FolderNotFound {
                    return
                } catch {
                    actionFailed = true
                    return
                }
            }
        }
        return true
    }

    // MARK: Папки

    func toggleExpanded(_ folder: Folder) {
        if collapsedFolderIds.contains(folder.id) {
            collapsedFolderIds.remove(folder.id)
        } else {
            collapsedFolderIds.insert(folder.id)
        }
    }

    func beginCreateFolder() {
        folderNameEditing = .create
        folderNameText = ""
    }

    func beginRenameFolder(_ folder: Folder) {
        folderNameEditing = .rename(folder)
        folderNameText = folder.name
    }

    func cancelFolderNameEditing() {
        folderNameEditing = nil
    }

    var canCommitFolderName: Bool {
        !folderNameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    func commitFolderName() -> Task<Void, Never>? {
        guard let editing = folderNameEditing else { return nil }
        folderNameEditing = nil
        let name = folderNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if case .rename(let folder) = editing, name == folder.name { return nil }
        let createdAt = now()
        return Task {
            do {
                switch editing {
                case .create:
                    try await repository.createFolder(id: UUID(), name: name, createdAt: createdAt)
                case .rename(let folder):
                    try await repository.renameFolder(id: folder.id, name: name)
                }
            } catch is FolderNotFound {
                // Папку удалили, пока шло переименование.
            } catch {
                actionFailed = true
            }
        }
    }

    func requestDeleteFolder(_ folder: Folder) {
        folderPendingDeletion = folder
    }

    /// Удаляет папку; её чаты возвращаются в «Recents», выбор чата не меняется.
    @discardableResult
    func confirmDeleteFolder() -> Task<Void, Never>? {
        guard let folder = folderPendingDeletion else { return nil }
        folderPendingDeletion = nil
        return Task {
            do {
                try await repository.deleteFolder(id: folder.id)
            } catch {
                actionFailed = true
            }
        }
    }

    func moveFolderUp(_ folder: Folder) async { await moveFolder(folder, by: -1) }
    func moveFolderDown(_ folder: Folder) async { await moveFolder(folder, by: 1) }

    private func moveFolder(_ folder: Folder, by offset: Int) async {
        guard let index = snapshot.folders.firstIndex(where: { $0.folder.id == folder.id }) else { return }
        let target = index + offset
        guard snapshot.folders.indices.contains(target) else { return }
        do {
            try await repository.moveFolder(id: folder.id, to: target)
        } catch is FolderNotFound {
            // Папку уже удалили.
        } catch {
            actionFailed = true
        }
    }

    func dismissActionFailure() {
        actionFailed = false
    }
}
