import Foundation
import GRDB

/// Строка таблицы `chat`. Доменный `Chat` о GRDB не знает — переводим здесь.
struct ChatRecord: Codable, Hashable, Sendable {
    static let databaseTableName = "chat"

    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// Колонка из миграции v2; `nil` — чат в «Recents».
    var folderId: UUID?

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let title = Column(CodingKeys.title)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
        static let folderId = Column(CodingKeys.folderId)
    }
}

extension ChatRecord: FetchableRecord, PersistableRecord {
    // Даты — числом: текстовый формат GRDB по умолчанию режет до миллисекунд,
    // и прочитанное значение не совпало бы с записанным.
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSinceReferenceDate
    }
}

extension ChatRecord {
    init(_ chat: Chat) {
        id = chat.id
        title = chat.title
        createdAt = chat.createdAt
        updatedAt = chat.updatedAt
        folderId = chat.folderId
    }

    var chat: Chat {
        Chat(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, folderId: folderId)
    }

    /// Чаты, новые (по `updatedAt`) сверху.
    static func byLastActivity() -> QueryInterfaceRequest<ChatRecord> {
        order(Columns.updatedAt.desc, Columns.createdAt.desc, Column.rowID.desc)
    }
}

extension Date {
    /// Значение даты в SQL-аргументах — в том же виде, что и в колонках записей.
    var databaseTimestamp: Double { timeIntervalSinceReferenceDate }
}
