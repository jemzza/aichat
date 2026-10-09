import Foundation

/// Фото во вложении к сообщению пользователя. Хранится в базе уже уменьшенным
/// JPEG (`ImageDownscaler`, длинная сторона ≤ 1024 px) — его же отправляем в LLM.
struct ImageAttachment: Identifiable, Hashable, Sendable {
    /// Столько фото принимает за один запрос vision-модель Groq — больше не прикрепляем.
    static let maxPerMessage = 3

    let id: UUID
    let jpegData: Data

    init(id: UUID = UUID(), jpegData: Data) {
        self.id = id
        self.jpegData = jpegData
    }
}
