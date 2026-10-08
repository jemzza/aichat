import AVFoundation
import OSLog

/// Журнал диктовки: какой путь выбран и почему не вышло. Текст речи сюда не пишем.
enum DictationLog {
    static let logger = Logger(subsystem: "com.example.aichat.app", category: "Dictation")
}

/// Разрешение на микрофон (спрашивает, если ещё не спрашивали).
enum MicrophonePermission {
    static func request() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .denied: false
        default: await AVAudioApplication.requestRecordPermission()
        }
    }
}

/// Языки диктовки по порядку: предпочитаемые пользователем, затем язык системы.
enum DictationLocales {
    static var candidates: [Locale] {
        var identifiers = Locale.preferredLanguages
        identifiers.append(Locale.current.identifier)
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            seen.insert(identifier).inserted ? Locale(identifier: identifier) : nil
        }
    }
}

/// Первое событие, после которого запись надо остановить: прерывание аудиосессии
/// или потеря устройства ввода (сняли гарнитуру).
enum AudioInterruptions {
    static func first() async {
        let center = NotificationCenter.default
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in center.notifications(named: AVAudioSession.interruptionNotification) { return }
            }
            group.addTask {
                for await notification in center.notifications(named: AVAudioSession.routeChangeNotification) {
                    let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    if raw.flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable { return }
                }
            }
            await group.next()
            group.cancelAll()
        }
    }
}
