import Foundation
import Observation

/// Экран Privacy: статус разрешений диктовки и «Delete all chats».
@MainActor
@Observable
final class PrivacyViewModel {
    struct PermissionState: Identifiable, Hashable {
        let permission: AppPermission
        let status: PermissionStatus
        var id: AppPermission { permission }
    }

    private(set) var permissions: [PermissionState] = []
    /// Показан диалог подтверждения удаления.
    var isConfirmingDeleteAll = false
    private(set) var isDeleting = false
    /// Удаление не удалось — алерт.
    var deleteFailed = false

    private let session: any ChatSession
    private let permissionStatus: any PermissionStatusProviding
    private let onDeletedAll: () -> Void

    /// - Parameter onDeletedAll: всё удалено — закрыть настройки.
    init(session: any ChatSession, permissions: any PermissionStatusProviding,
         onDeletedAll: @escaping () -> Void = {}) {
        self.session = session
        permissionStatus = permissions
        self.onDeletedAll = onDeletedAll
        refreshPermissions()
    }

    /// При открытии и возврате из системных Настроек.
    func refreshPermissions() {
        permissions = AppPermission.allCases.map {
            PermissionState(permission: $0, status: permissionStatus.status(of: $0))
        }
    }

    func requestDeleteAll() {
        isConfirmingDeleteAll = true
    }

    /// Подтверждение в диалоге. Возвращает задачу удаления (для тестов); `nil` — удаление уже идёт.
    @discardableResult
    func confirmDeleteAll() -> Task<Void, Never>? {
        isConfirmingDeleteAll = false
        guard !isDeleting else { return nil }
        isDeleting = true
        return Task {
            defer { isDeleting = false }
            do {
                try await session.deleteAll()
                onDeletedAll()
            } catch {
                deleteFailed = true
            }
        }
    }
}
