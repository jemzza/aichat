import Foundation
import GRDB

/// Строка таблицы `attachment`: фото сообщения пользователя (JPEG в BLOB).
/// Удаляется каскадом вместе с сообщением.
struct AttachmentRecord: Codable, Hashable, Sendable {
    static let databaseTableName = "attachment"

    var id: UUID
    var messageId: UUID
    /// Порядок фото внутри сообщения.
    var position: Int
    var data: Data

    enum Columns {
        static let messageId = Column(CodingKeys.messageId)
        static let position = Column(CodingKeys.position)
    }
}

extension AttachmentRecord: FetchableRecord, PersistableRecord {}

extension AttachmentRecord {
    static func records(for message: Message) -> [AttachmentRecord] {
        message.images.enumerated().map { position, image in
            AttachmentRecord(id: image.id, messageId: message.id, position: position, data: image.jpegData)
        }
    }

    var image: ImageAttachment {
        ImageAttachment(id: id, jpegData: data)
    }

    /// Фото этих сообщений по порядку, сгруппированные по сообщению. Пустой список — без запроса.
    static func imagesByMessage(_ messageIds: [UUID], _ db: Database) throws -> [UUID: [ImageAttachment]] {
        guard !messageIds.isEmpty else { return [:] }
        let records = try AttachmentRecord
            .filter(messageIds.contains(Columns.messageId))
            .order(Columns.messageId, Columns.position)
            .fetchAll(db)
        return Dictionary(grouping: records, by: \.messageId).mapValues { $0.map(\.image) }
    }
}
