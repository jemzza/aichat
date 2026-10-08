import Foundation
import GRDB

/// Строка таблицы `message`. `MessageFailure` разложен на две колонки.
struct MessageRecord: Codable, Hashable, Sendable {
    static let databaseTableName = "message"

    var id: UUID
    var chatId: UUID
    var role: String
    var text: String
    var status: String
    var failureKind: String?
    var failureRetryAt: Date?
    var createdAt: Date

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let chatId = Column(CodingKeys.chatId)
        static let role = Column(CodingKeys.role)
        static let text = Column(CodingKeys.text)
        static let status = Column(CodingKeys.status)
        static let failureKind = Column(CodingKeys.failureKind)
        static let failureRetryAt = Column(CodingKeys.failureRetryAt)
        static let createdAt = Column(CodingKeys.createdAt)
    }
}

extension MessageRecord: FetchableRecord, PersistableRecord {
    // См. `ChatRecord`: даты храним числом, без потери точности.
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSinceReferenceDate
    }
}

extension MessageRecord {
    init(_ message: Message) {
        id = message.id
        chatId = message.chatId
        role = message.role.rawValue
        text = message.text
        status = message.status.rawValue
        failureKind = message.failure?.kind.rawValue
        failureRetryAt = message.failure?.retryAt
        createdAt = message.createdAt
    }

    /// - Parameter images: фото сообщения (таблица `attachment`).
    /// - Throws: `InvalidDatabaseValue`, если в базе неизвестные роль, статус или вид ошибки.
    func message(images: [ImageAttachment] = []) throws -> Message {
        guard let role = MessageRole(rawValue: role) else {
            throw InvalidDatabaseValue(column: "role", value: role)
        }
        guard let status = MessageStatus(rawValue: status) else {
            throw InvalidDatabaseValue(column: "status", value: status)
        }
        var failure: MessageFailure?
        if let failureKind {
            guard let kind = ErrorKind(rawValue: failureKind) else {
                throw InvalidDatabaseValue(column: "failureKind", value: failureKind)
            }
            failure = MessageFailure(kind: kind, retryAt: failureRetryAt)
        }
        return Message(id: id, chatId: chatId, role: role, text: text, status: status,
                       failure: failure, images: images, createdAt: createdAt)
    }

    /// Доменные сообщения вместе с их фото — одним дополнительным запросом.
    static func messages(_ records: [MessageRecord], _ db: Database) throws -> [Message] {
        let images = try AttachmentRecord.imagesByMessage(records.map(\.id), db)
        return try records.map { try $0.message(images: images[$0.id] ?? []) }
    }

    /// Порядок сообщений: по времени, при равенстве — по порядку вставки.
    static func chronological() -> QueryInterfaceRequest<MessageRecord> {
        order(Columns.createdAt, Column.rowID)
    }
}
