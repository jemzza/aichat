import Foundation
import GRDB

/// База приложения: соединение GRDB + схема (миграции).
/// Только Data-слой знает о GRDB; наружу база видна через `ChatRepository`.
struct AppDatabase: Sendable {
    let writer: any DatabaseWriter

    /// Применяет миграции к переданному соединению.
    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Файл в Application Support. `DatabasePool` — чтения не ждут запись стрима.
    static func onDisk(fileName: String = "AIChat.sqlite") throws -> AppDatabase {
        let folder = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return try onDisk(at: folder.appendingPathComponent(fileName, isDirectory: false))
    }

    static func onDisk(at url: URL) throws -> AppDatabase {
        try AppDatabase(DatabasePool(path: url.path, configuration: makeConfiguration()))
    }

    /// Для тестов и превью: каждая база — отдельная, живёт, пока жив объект.
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: makeConfiguration()))
    }

    private static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        // По умолчанию так и есть, но каскадное удаление сообщений и
        // возврат чатов удалённой папки в «Recents» держатся именно на этом.
        configuration.foreignKeysEnabled = true
        return configuration
    }

    // MARK: Миграции

    /// Схема. Опубликованные миграции не меняются — только новые `registerMigration`.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // Таблицы с UUID-ключом сохраняют rowid — он задаёт порядок вставки.
            try db.create(table: ChatRecord.databaseTableName) { t in
                t.primaryKey("id", .blob)
                t.column("title", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull().indexed()
            }

            try db.create(table: MessageRecord.databaseTableName) { t in
                t.primaryKey("id", .blob)
                // Индекс по chatId покрывает составной индекс ниже.
                t.belongsTo(ChatRecord.databaseTableName, onDelete: .cascade, indexed: false)
                    .notNull()
                t.column("role", .text).notNull()
                t.column("text", .text).notNull()
                t.column("status", .text).notNull().indexed()
                t.column("failureKind", .text)
                t.column("failureRetryAt", .double)
                t.column("createdAt", .double).notNull()
            }
            try db.create(
                index: "message_on_chatId_createdAt",
                on: MessageRecord.databaseTableName,
                columns: ["chatId", "createdAt"]
            )
        }

        migrator.registerMigration("v2") { db in
            // Папки одного уровня с ручным порядком.
            try db.create(table: FolderRecord.databaseTableName) { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("position", .integer).notNull().indexed()
                t.column("createdAt", .double).notNull()
            }
            // Чат — максимум в одной папке. Удаление папки возвращает чаты в «Recents»;
            // существующие чаты получают NULL, т. е. тоже оказываются в «Recents».
            try db.alter(table: ChatRecord.databaseTableName) { t in
                t.add(column: "folderId", .blob)
                    .references(FolderRecord.databaseTableName, onDelete: .setNull)
            }
            try db.create(index: "chat_on_folderId", on: ChatRecord.databaseTableName, columns: ["folderId"])
        }

        // «v3» в main появилась раньше «v2» (папки делались в отдельной ветке). GRDB применяет
        // все неприменённые миграции по порядку регистрации, даже если более поздняя уже
        // применена, поэтому база с v1+v3 получит v2 при обновлении. Таблицы независимы.
        migrator.registerMigration("v3") { db in
            // Фото сообщений. Отдельная таблица: запись стрима (`updateMessage`) не трогает
            // строки с BLOB, а история читает фото только нужных сообщений.
            // Удаление чата → сообщения → фото каскадом.
            try db.create(table: AttachmentRecord.databaseTableName) { t in
                t.primaryKey("id", .blob)
                t.belongsTo(MessageRecord.databaseTableName, onDelete: .cascade).notNull()
                t.column("position", .integer).notNull()
                t.column("data", .blob).notNull()
            }
        }
        return migrator
    }
}

/// В базе лежит значение, которого нет в доменном перечислении.
struct InvalidDatabaseValue: Error, Hashable, Sendable {
    let column: String
    let value: String
}
