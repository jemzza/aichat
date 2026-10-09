import Foundation

/// Папка в сайдбаре. Папки одного уровня; чат лежит максимум в одной папке
/// (`Chat.folderId`). Удаление папки чаты не удаляет — они возвращаются в «Recents».
struct Folder: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    /// Ручной порядок, 0..n-1 без пропусков. Задаёт репозиторий.
    var position: Int
    let createdAt: Date
}
