import Foundation
import GRDB

/// Строка таблицы `folder` (миграция v2).
struct FolderRecord: Codable, Hashable, Sendable {
    static let databaseTableName = "folder"

    var id: UUID
    var name: String
    var position: Int
    var createdAt: Date

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let position = Column(CodingKeys.position)
        static let createdAt = Column(CodingKeys.createdAt)
    }
}

extension FolderRecord: FetchableRecord, PersistableRecord {
    // Даты — числом, как у `ChatRecord`.
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSinceReferenceDate
    }
}

extension FolderRecord {
    init(_ folder: Folder) {
        id = folder.id
        name = folder.name
        position = folder.position
        createdAt = folder.createdAt
    }

    var folder: Folder {
        Folder(id: id, name: name, position: position, createdAt: createdAt)
    }

    /// Папки в ручном порядке.
    static func ordered() -> QueryInterfaceRequest<FolderRecord> {
        order(Columns.position, Column.rowID)
    }
}
