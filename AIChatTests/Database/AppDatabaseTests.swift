import Foundation
import GRDB
import Testing
@testable import AIChat

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func makeChat(at seconds: TimeInterval = 0) -> Chat {
    Chat(id: UUID(), title: "Chat", createdAt: t0.addingTimeInterval(seconds),
         updatedAt: t0.addingTimeInterval(seconds))
}

@Suite("AppDatabase")
struct AppDatabaseTests {
    @Test func migrationCreatesSchema() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.read { db in
            #expect(try db.tableExists("chat"))
            #expect(try db.tableExists("message"))
            #expect(try db.tableExists("folder"))
            let foreignKeys = try db.foreignKeys(on: "message")
            #expect(foreignKeys.map(\.destinationTable) == ["chat"])
            #expect(try AppDatabase.migrator.hasCompletedMigrations(db))
        }
    }

    @Test func migrationIsIdempotent() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        _ = try AppDatabase(queue)
        #expect(try queue.read { try AppDatabase.migrator.appliedIdentifiers($0) } == ["v1", "v2", "v3"])
    }

    @Test func recordsRoundTripDomainModels() throws {
        let database = try AppDatabase.inMemory()
        // Дробные секунды: текстовый формат дат GRDB их бы обрезал.
        let chat = Chat(id: UUID(), title: "Chat", createdAt: Date(timeIntervalSinceReferenceDate: 1.123456789),
                        updatedAt: Date(timeIntervalSinceReferenceDate: 2.987654321))
        let failed = Message(chatId: chat.id, role: .assistant, text: "partial", status: .failed,
                             failure: MessageFailure(kind: .rateLimited, retryAt: Date(timeIntervalSinceReferenceDate: 3.5)),
                             createdAt: Date(timeIntervalSinceReferenceDate: 4.000001))
        let sent = Message(chatId: chat.id, role: .user, text: "Hi", status: .sent,
                           createdAt: Date(timeIntervalSinceReferenceDate: 5))

        try database.writer.write { db in
            try ChatRecord(chat).insert(db)
            try MessageRecord(failed).insert(db)
            try MessageRecord(sent).insert(db)
        }

        let (chats, messages) = try database.writer.read { db in
            (try ChatRecord.fetchAll(db).map(\.chat),
             try MessageRecord.chronological().fetchAll(db).map { try $0.message() })
        }
        #expect(chats == [chat])
        #expect(messages == [failed, sent])
    }

    @Test func unknownStatusThrows() throws {
        let database = try AppDatabase.inMemory()
        let chat = makeChat()
        var record = MessageRecord(Message(chatId: chat.id, role: .user, text: "", status: .sent, createdAt: t0))
        record.status = "archived"
        let stored = record
        try database.writer.write { db in
            try ChatRecord(chat).insert(db)
            try stored.insert(db)
        }
        let fetched = try database.writer.read { try MessageRecord.fetchOne($0) }
        #expect(throws: InvalidDatabaseValue(column: "status", value: "archived")) {
            try fetched?.message()
        }
    }

    @Test func deletingChatCascadesToMessages() throws {
        let database = try AppDatabase.inMemory()
        let chat = makeChat()
        let other = makeChat(at: 1)
        try database.writer.write { db in
            try ChatRecord(chat).insert(db)
            try ChatRecord(other).insert(db)
            try MessageRecord(Message(chatId: chat.id, role: .user, text: "a", status: .sent, createdAt: t0)).insert(db)
            try MessageRecord(Message(chatId: other.id, role: .user, text: "b", status: .sent, createdAt: t0)).insert(db)
        }

        let deleted = try database.writer.write { try ChatRecord.deleteOne($0, key: chat.id) }

        #expect(deleted)
        let remaining = try database.writer.read { try MessageRecord.fetchAll($0).map(\.chatId) }
        #expect(remaining == [other.id])
    }

    /// База v1 с данными: после миграции v3 всё на месте, у сообщений нет фото.
    @Test func migrationFromV1KeepsDataAndAddsAttachments() async throws {
        let queue = try DatabaseQueue()
        // Только первая миграция — как у установленной раньше версии.
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        let chat = makeChat()
        let message = Message(chatId: chat.id, role: .user, text: "old", status: .sent, createdAt: t0)
        try await queue.write { db in
            // Чат — сырым SQL: `ChatRecord` уже знает `folderId` из v2, а база ещё на v1.
            try db.execute(
                sql: "INSERT INTO chat (id, title, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [chat.id, chat.title, chat.createdAt.databaseTimestamp, chat.updatedAt.databaseTimestamp]
            )
            try MessageRecord(message).insert(db)
        }

        let database = try AppDatabase(queue)
        let repository = GRDBChatRepository(database: database)

        #expect(try await queue.read { try $0.tableExists("attachment") })
        #expect(try await firstValue(of: repository.observeMessages(chatId: chat.id)) == [message])
    }

    @Test func deletingChatCascadesToAttachments() async throws {
        let database = try AppDatabase.inMemory()
        let repository = GRDBChatRepository(database: database)
        let chat = makeChat()
        let photo = Message(chatId: chat.id, role: .user, text: "", status: .sent,
                            images: [ImageAttachment(jpegData: Data([1]))], createdAt: t0)
        try await repository.insertChat(chat, firstMessage: photo)
        #expect(try await database.writer.read { try AttachmentRecord.fetchCount($0) } == 1)

        try await repository.deleteChat(id: chat.id)

        #expect(try await database.writer.read { try AttachmentRecord.fetchCount($0) } == 0)
    }

    @Test func messageWithoutChatViolatesForeignKey() throws {
        let database = try AppDatabase.inMemory()
        let orphan = Message(chatId: UUID(), role: .user, text: "", status: .sent, createdAt: t0)
        #expect(throws: DatabaseError.self) {
            try database.writer.write { try MessageRecord(orphan).insert($0) }
        }
    }

    @Test func messagesAreOrderedByTimeThenRowID() throws {
        let database = try AppDatabase.inMemory()
        let chat = makeChat()
        let late = Message(chatId: chat.id, role: .user, text: "late", status: .sent, createdAt: t0.addingTimeInterval(10))
        let sameA = Message(chatId: chat.id, role: .user, text: "a", status: .sent, createdAt: t0)
        let sameB = Message(chatId: chat.id, role: .assistant, text: "b", status: .done, createdAt: t0)
        try database.writer.write { db in
            try ChatRecord(chat).insert(db)
            for message in [late, sameA, sameB] { try MessageRecord(message).insert(db) }
        }

        let ids = try database.writer.read { try MessageRecord.chronological().fetchAll($0).map(\.id) }
        #expect(ids == [sameA.id, sameB.id, late.id])
    }

    @Test func chatsAreOrderedByLastActivity() throws {
        let database = try AppDatabase.inMemory()
        var older = makeChat(at: 0)
        let newer = makeChat(at: 5)
        older.updatedAt = t0.addingTimeInterval(10)
        try database.writer.write { db in
            try ChatRecord(newer).insert(db)
            try ChatRecord(older).insert(db)
        }

        let ids = try database.writer.read { try ChatRecord.byLastActivity().fetchAll($0).map(\.id) }
        #expect(ids == [older.id, newer.id])
    }

    // MARK: Миграция v2 (папки)

    @Test func migrationV1ToV2KeepsData() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")

        // Записи уже знают о `folderId`, поэтому данные v1 кладём сырым SQL.
        let chatA = makeChat(at: 0)
        let chatB = makeChat(at: 10)
        let stored = [
            Message(chatId: chatA.id, role: .user, text: "Hi", status: .sent, createdAt: t0),
            Message(chatId: chatA.id, role: .assistant, text: "partial", status: .failed,
                    failure: MessageFailure(kind: .rateLimited, retryAt: t0.addingTimeInterval(60)),
                    createdAt: t0.addingTimeInterval(1)),
            Message(chatId: chatB.id, role: .user, text: "Later", status: .pending,
                    createdAt: t0.addingTimeInterval(10)),
        ]
        try await queue.write { db in
            for chat in [chatA, chatB] {
                try db.execute(
                    sql: "INSERT INTO chat (id, title, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                    arguments: [chat.id, chat.title, chat.createdAt.databaseTimestamp, chat.updatedAt.databaseTimestamp]
                )
            }
            for message in stored {
                try db.execute(
                    sql: """
                        INSERT INTO message (id, chatId, role, text, status, failureKind, failureRetryAt, createdAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [message.id, message.chatId, message.role.rawValue, message.text,
                                message.status.rawValue, message.failure?.kind.rawValue,
                                message.failure?.retryAt?.databaseTimestamp, message.createdAt.databaseTimestamp]
                )
            }
        }

        let database = try AppDatabase(queue)

        try await queue.read { db in
            #expect(try AppDatabase.migrator.appliedIdentifiers(db) == ["v1", "v2", "v3"])
            #expect(try ChatRecord.byLastActivity().fetchAll(db).map(\.chat) == [chatB, chatA])
            #expect(try MessageRecord.chronological().fetchAll(db).map { try $0.message() } == stored)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat WHERE folderId IS NOT NULL") == 0)
            #expect(try FolderRecord.fetchCount(db) == 0)
            let foreignKey = try Row.fetchOne(db, sql: "SELECT * FROM pragma_foreign_key_list('chat')")
            #expect(foreignKey?["table"] == "folder")
            #expect(foreignKey?["from"] == "folderId")
            #expect(foreignKey?["on_delete"] == "SET NULL")
        }

        // После миграции папки работают и со старыми чатами.
        let repository = GRDBChatRepository(database: database)
        let folder = UUID()
        try await repository.createFolder(id: folder, name: "Old chats", createdAt: t0)
        try await repository.moveChat(id: chatA.id, toFolder: folder)
        let snapshot = try await firstValue(of: repository.observeSidebar()) { $0.recents.count == 1 }
        #expect(snapshot.folders.first?.chats.map(\.id) == [chatA.id])
        #expect(snapshot.recents.map(\.id) == [chatB.id])
    }

    /// База из main до слияния папок: применены v1 и v3 (фото), v2 (папки) — нет.
    /// При обновлении GRDB должен применить пропущенную v2, не трогая данные.
    @Test func databaseWithV1AndV3GetsFoldersMigration() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        let chat = makeChat()
        try await queue.write { db in
            // То, что сделала бы v3 из main, — вручную: мигратор без v2 из тестов недоступен.
            try db.execute(sql: """
                CREATE TABLE attachment (
                  id BLOB PRIMARY KEY NOT NULL,
                  messageId BLOB NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                  position INTEGER NOT NULL,
                  data BLOB NOT NULL)
                """)
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v3')")
            try db.execute(
                sql: "INSERT INTO chat (id, title, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [chat.id, chat.title, chat.createdAt.databaseTimestamp, chat.updatedAt.databaseTimestamp]
            )
        }
        #expect(try await queue.read { try AppDatabase.migrator.appliedIdentifiers($0) } == ["v1", "v3"])

        _ = try AppDatabase(queue)

        try await queue.read { db throws in
            #expect(try AppDatabase.migrator.appliedIdentifiers(db) == ["v1", "v2", "v3"])
            #expect(try db.tableExists("folder"))
            #expect(try db.tableExists("attachment"))
            #expect(try ChatRecord.fetchAll(db).map(\.chat) == [chat])
        }
    }

    @Test func deletingFolderSetsChatFolderToNull() throws {
        let database = try AppDatabase.inMemory()
        let folder = Folder(id: UUID(), name: "Folder", position: 0, createdAt: t0)
        var chat = makeChat()
        chat.folderId = folder.id
        try database.writer.write { db in
            try FolderRecord(folder).insert(db)
            try ChatRecord(chat).insert(db)
            try MessageRecord(Message(chatId: chat.id, role: .user, text: "a", status: .sent, createdAt: t0)).insert(db)
        }

        let deleted = try database.writer.write { try FolderRecord.deleteOne($0, key: folder.id) }

        #expect(deleted)
        let (chats, messageCount) = try database.writer.read { db in
            (try ChatRecord.fetchAll(db).map(\.chat), try MessageRecord.fetchCount(db))
        }
        chat.folderId = nil
        #expect(chats == [chat])
        #expect(messageCount == 1)
    }

    @Test func chatWithUnknownFolderViolatesForeignKey() throws {
        let database = try AppDatabase.inMemory()
        var chat = makeChat()
        chat.folderId = UUID()
        let orphan = chat
        #expect(throws: DatabaseError.self) {
            try database.writer.write { try ChatRecord(orphan).insert($0) }
        }
    }
}
