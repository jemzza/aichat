import AVFoundation
import Speech

/// Статус разрешений диктовки из `AVAudioApplication` и `SFSpeechRecognizer`.
@MainActor
final class SystemPermissionStatus: PermissionStatusProviding {
    func status(of permission: AppPermission) -> PermissionStatus {
        switch permission {
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: .granted
            case .denied: .denied
            default: .notDetermined
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: .granted
            case .denied: .denied
            case .restricted: .restricted
            default: .notDetermined
            }
        }
    }
}
