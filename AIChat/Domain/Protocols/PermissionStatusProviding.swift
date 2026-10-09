import Foundation

/// Системные разрешения, статус которых показывает экран Privacy.
enum AppPermission: CaseIterable, Sendable, Hashable {
    case microphone
    case speechRecognition
}

enum PermissionStatus: Sendable, Hashable {
    case notDetermined
    case granted
    case denied
    /// Запрещено политикой устройства (родительский контроль, MDM).
    case restricted
}

/// Только чтение статуса — запрашивает разрешения сама диктовка.
@MainActor
protocol PermissionStatusProviding: AnyObject {
    func status(of permission: AppPermission) -> PermissionStatus
}
