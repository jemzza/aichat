#if DEBUG
import Foundation

/// Демо-данные для превью и `-mockData`: чаты с сообщениями во всех статусах.
/// Это содержимое переписки, а не строки интерфейса, поэтому в String Catalog не идёт.
enum PreviewData {
    static let now = Date()

    static let swiftChat = Chat(id: UUID(), title: "Swift concurrency basics",
                                createdAt: now.addingTimeInterval(-600), updatedAt: now.addingTimeInterval(-540))
    static let errorsChat = Chat(id: UUID(), title: "Trip ideas",
                                 createdAt: now.addingTimeInterval(-90_000), updatedAt: now.addingTimeInterval(-86_400))
    static let offlineChat = Chat(id: UUID(), title: "Recipe for pancakes",
                                  createdAt: now.addingTimeInterval(-400_000), updatedAt: now.addingTimeInterval(-399_000))

    static let chats = [swiftChat, errorsChat, offlineChat]

    static let messages: [Message] = [
        // Обычный диалог с markdown и блоком кода.
        Message(chatId: swiftChat.id, role: .user, text: "What is an actor in Swift?",
                status: .sent, createdAt: now.addingTimeInterval(-600)),
        Message(chatId: swiftChat.id, role: .assistant, text: """
            ## Actors

            An **actor** is a reference type that protects its mutable state:
            - only one task touches the state at a time;
            - calls from outside are `await`ed.

            ```swift
            actor Counter {
                private var value = 0
                func increment() { value += 1 }
            }
            ```

            More in [The Swift Programming Language](https://docs.swift.org/swift-book/).
            """, status: .done, createdAt: now.addingTimeInterval(-590)),
        Message(chatId: swiftChat.id, role: .user, text: "And how is it different from a class with a lock?",
                status: .sent, createdAt: now.addingTimeInterval(-550)),
        Message(chatId: swiftChat.id, role: .assistant, text: "The compiler checks isolation for you, so",
                status: .streaming, createdAt: now.addingTimeInterval(-540)),

        // Ошибки и прерывания.
        Message(chatId: errorsChat.id, role: .user, text: "Plan a weekend in Lisbon",
                status: .sent, createdAt: now.addingTimeInterval(-90_000)),
        Message(chatId: errorsChat.id, role: .assistant, text: "",
                status: .failed, failure: MessageFailure(kind: .rateLimited, retryAt: now.addingTimeInterval(30)),
                createdAt: now.addingTimeInterval(-89_990)),
        Message(chatId: errorsChat.id, role: .user, text: "Something cheaper?",
                status: .sent, createdAt: now.addingTimeInterval(-88_000)),
        Message(chatId: errorsChat.id, role: .assistant, text: "Consider Porto: it is smaller and",
                status: .cancelled, createdAt: now.addingTimeInterval(-87_990)),
        Message(chatId: errorsChat.id, role: .user, text: "What about trains?",
                status: .sent, createdAt: now.addingTimeInterval(-86_410)),
        Message(chatId: errorsChat.id, role: .assistant, text: "Trains between Lisbon and",
                status: .interrupted, createdAt: now.addingTimeInterval(-86_400)),

        // Отправка без сети.
        Message(chatId: offlineChat.id, role: .user, text: "Fluffy pancakes without eggs?",
                status: .sent, createdAt: now.addingTimeInterval(-400_000)),
        Message(chatId: offlineChat.id, role: .assistant, text: "",
                status: .failed, failure: MessageFailure(kind: .offline),
                createdAt: now.addingTimeInterval(-399_990)),
        Message(chatId: offlineChat.id, role: .user, text: "Then with banana instead?",
                status: .pending, createdAt: now.addingTimeInterval(-399_000)),
    ]

    static func repository() -> InMemoryChatRepository {
        InMemoryChatRepository(chats: chats, messages: messages)
    }

    // MARK: Папки — для превью сайдбара

    static let travelFolder = Folder(id: UUID(), name: "Travel", position: 0, createdAt: now.addingTimeInterval(-500_000))
    static let workFolder = Folder(id: UUID(), name: "Work", position: 1, createdAt: now.addingTimeInterval(-400_000))
    static let emptyFolder = Folder(id: UUID(), name: "Ideas", position: 2, createdAt: now.addingTimeInterval(-300_000))
    static let folders = [travelFolder, workFolder, emptyFolder]

    /// Те же чаты, но «Trip ideas» лежит в «Travel», «Swift concurrency basics» — в «Work»,
    /// «Ideas» пустая, остальные — в «Recents».
    static func repositoryWithFolders() -> InMemoryChatRepository {
        let placement = [errorsChat.id: travelFolder.id, swiftChat.id: workFolder.id]
        let placed = chats.map { chat in
            var chat = chat
            chat.folderId = placement[chat.id]
            return chat
        }
        return InMemoryChatRepository(folders: folders, chats: placed, messages: messages)
    }
}
#endif
