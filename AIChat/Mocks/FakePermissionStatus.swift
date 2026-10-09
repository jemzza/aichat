#if DEBUG
import Foundation

/// Разрешения, которые задаёт тест или превью.
@MainActor
final class FakePermissionStatus: PermissionStatusProviding {
    var statuses: [AppPermission: PermissionStatus]

    init(_ statuses: [AppPermission: PermissionStatus] = [.microphone: .granted, .speechRecognition: .notDetermined]) {
        self.statuses = statuses
    }

    func status(of permission: AppPermission) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }
}
#endif
