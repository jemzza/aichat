import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Объявлен в `project.yml` (`UTExportedTypeDeclarations`).
    static let chatReference = UTType(exportedAs: "com.example.aichat.chat-reference")
}

/// Что переносится при перетаскивании чата: только id, не содержимое.
/// Свой тип, а не `UUID`/`String`: в сайдбар не упадёт случайный текст из другого
/// приложения, а другое приложение не примет перенос как текст.
struct ChatDragItem: Codable, Hashable, Sendable, Transferable {
    let chatId: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .chatReference)
    }
}
