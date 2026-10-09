import Foundation
import Observation

/// Подэкран Notifications. Разрешение у системы просим при первом включении
/// переключателя, а не при запуске. Запрещено в системе — переключатели выключены.
@MainActor
@Observable
final class NotificationSettingsViewModel {
    enum Kind: CaseIterable, Hashable {
        /// Готовый ответ.
        case replies
        /// Outbox отправил сообщения, ждавшие сети.
        case queuedSent
    }

    /// `nil` — статус ещё не прочитан.
    private(set) var authorization: NotificationAuthorization?
    /// Идёт системный запрос разрешения — переключатели недоступны.
    private(set) var isRequesting = false

    @ObservationIgnored private let settings: any SettingsStoring
    @ObservationIgnored private let scheduler: any LocalNotificationScheduling

    init(settings: any SettingsStoring, scheduler: any LocalNotificationScheduling) {
        self.settings = settings
        self.scheduler = scheduler
    }

    /// Уведомления запрещены в системных Настройках.
    var isDeniedInSystem: Bool { authorization == .denied }

    var areTogglesEnabled: Bool { authorization != nil && !isDeniedInSystem && !isRequesting }

    /// Что показывает переключатель: при запрете в системе — выключен, что бы ни лежало в настройках.
    func isOn(_ kind: Kind) -> Bool {
        !isDeniedInSystem && stored(kind)
    }

    /// При открытии экрана и возврате из системных Настроек.
    func refresh() async {
        authorization = await scheduler.authorization()
    }

    func setEnabled(_ kind: Kind, _ isEnabled: Bool) async {
        guard isEnabled else {
            store(kind, false)
            return
        }
        guard !isRequesting else { return }
        var status = await scheduler.authorization()
        if status == .notDetermined {
            isRequesting = true
            _ = await scheduler.requestAuthorization()
            isRequesting = false
            status = await scheduler.authorization()
        }
        authorization = status
        // Без разрешения сохранённое значение не трогаем: разрешат в системе — вернётся как было.
        if status == .authorized { store(kind, true) }
    }

    private func stored(_ kind: Kind) -> Bool {
        switch kind {
        case .replies: settings.notifyOnReply
        case .queuedSent: settings.notifyOnQueuedSent
        }
    }

    private func store(_ kind: Kind, _ value: Bool) {
        switch kind {
        case .replies: settings.notifyOnReply = value
        case .queuedSent: settings.notifyOnQueuedSent = value
        }
    }
}
