import Foundation

/// Всё, что показывает сайдбар, одним согласованным снимком: чат не может
/// оказаться одновременно в папке и в «Recents» на время переноса.
struct SidebarSnapshot: Hashable, Sendable {
    struct Section: Identifiable, Hashable, Sendable {
        let folder: Folder
        /// Новые (по `updatedAt`) сверху.
        let chats: [Chat]

        var id: UUID { folder.id }
    }

    /// По `position`.
    var folders: [Section]
    /// Чаты без папки, новые сверху.
    var recents: [Chat]

    static let empty = SidebarSnapshot(folders: [], recents: [])
}

extension SidebarSnapshot {
    /// Раскладывает чаты по папкам. Правило группировки — одно на все реализации репозитория.
    /// - Parameters:
    ///   - folders: уже в порядке `position`.
    ///   - chats: уже в порядке «новые сверху»; порядок внутри секций сохраняется.
    init(folders: [Folder], chats: [Chat]) {
        let byFolder = Dictionary(grouping: chats.filter { $0.folderId != nil }) { $0.folderId }
        self.folders = folders.map { Section(folder: $0, chats: byFolder[$0.id] ?? []) }
        let known = Set(folders.map(\.id))
        // Чат со ссылкой на неизвестную папку показываем в «Recents», а не теряем.
        recents = chats.filter { chat in chat.folderId.map { !known.contains($0) } ?? true }
    }
}
