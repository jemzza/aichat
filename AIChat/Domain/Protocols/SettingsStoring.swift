import Foundation
import Observation

/// Настройки пользователя. Хранятся вне базы (`UserDefaults`, см. docs/task.md):
/// это не данные переписки, и они нужны раньше, чем откроется база (тема окна).
@MainActor
protocol SettingsStoring: AnyObject, Observable {
    var appearance: AppearancePreference { get set }
    /// Уведомлять о готовом ответе, пока приложение не активно.
    var notifyOnReply: Bool { get set }
    /// Уведомлять, когда outbox отправил сообщения, ждавшие сети.
    var notifyOnQueuedSent: Bool { get set }
}
