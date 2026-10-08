import Foundation
import Testing
@testable import AIChat

/// Шаг 1.5: процесс умер посреди стрима — при следующем запуске ответ `interrupted`.
@Suite("Launch recovery")
struct LaunchRecoveryTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func streamingRepliesBecomeInterruptedOnRelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("AIChat.sqlite")

        let chat = Chat(id: UUID(), title: "Chat", createdAt: t0, updatedAt: t0)
        let question = Message(chatId: chat.id, role: .user, text: "Hi", status: .sent, createdAt: t0)
        let streaming = Message(chatId: chat.id, role: .assistant, text: "Half an ans", status: .streaming,
                                createdAt: t0.addingTimeInterval(1))
        let done = Message(chatId: chat.id, role: .assistant, text: "Done", status: .done,
                           createdAt: t0.addingTimeInterval(2))

        // Первый «запуск»: ответ остался в `streaming`, процесс завершился.
        do {
            let repository = GRDBChatRepository(database: try AppDatabase.onDisk(at: url))
            try await repository.insertChat(chat, firstMessage: question)
            try await repository.insertMessage(streaming)
            try await repository.insertMessage(done)
        }

        // Второй запуск — та же база с диска.
        let repository = try await GRDBChatRepository.launch(database: try AppDatabase.onDisk(at: url))

        let messages = try await firstValue(of: repository.observeMessages(chatId: chat.id))
        #expect(messages.map(\.status) == [.sent, .interrupted, .done])
        #expect(messages[1].text == "Half an ans")
        #expect(messages[1].status.isRetryable)
    }

    @Test func launchWithoutStreamingChangesNothing() async throws {
        let database = try AppDatabase.inMemory()
        let chat = Chat(id: UUID(), title: "Chat", createdAt: t0, updatedAt: t0)
        let first = Message(chatId: chat.id, role: .user, text: "Hi", status: .pending, createdAt: t0)
        try await GRDBChatRepository(database: database).insertChat(chat, firstMessage: first)

        let repository = try await GRDBChatRepository.launch(database: database)

        #expect(try await firstValue(of: repository.observeMessages(chatId: chat.id)) == [first])
    }
}
