import Foundation
import os
import Speech

/// Распознавание записи на `SFSpeechRecognizer`: на устройстве, если язык это поддерживает;
/// иначе, если есть сеть, — через серверы Apple. Путь iOS 18 и запасной путь iOS 26.
@MainActor
final class RecognizerSpeechTranscriber: SpeechTranscribing {
    private let connectivity: any ConnectivityMonitoring

    init(connectivity: any ConnectivityMonitoring) {
        self.connectivity = connectivity
    }

    func prepare() async throws {
        guard await Self.requestAuthorization() else { throw DictationUnavailability.recognitionDenied }
    }

    func transcribe(fileAt url: URL, onDownloadProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await prepare()
        let (locale, onDevice) = try Self.recognizerLocale(isOnline: connectivity.isOnline)
        DictationLog.logger.info(
            "Recognizer: \(locale.identifier, privacy: .public), onDevice=\(onDevice, privacy: .public)"
        )
        do {
            return try await Self.recognize(fileAt: url, locale: locale, onDevice: onDevice)
        } catch {
            DictationLog.logger.error("Recognizer: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Язык распознавания — первый подходящий язык пользователя: сначала на устройстве,
    /// затем (если есть сеть) — серверный.
    private static func recognizerLocale(isOnline: Bool) throws -> (Locale, onDevice: Bool) {
        let recognizers = DictationLocales.candidates.compactMap { SFSpeechRecognizer(locale: $0) }
        let summary = recognizers.map {
            "\($0.locale.identifier) onDevice=\($0.supportsOnDeviceRecognition) available=\($0.isAvailable)"
        }
        DictationLog.logger.info(
            "Recognizers: \(summary.joined(separator: "; "), privacy: .public), online=\(isOnline, privacy: .public)"
        )
        if let local = recognizers.first(where: { $0.supportsOnDeviceRecognition }) {
            return (local.locale, true)
        }
        guard isOnline else { throw DictationUnavailability.languageNotSupported }
        guard let remote = recognizers.first(where: \.isAvailable) else {
            throw DictationUnavailability.serviceUnavailable
        }
        return (remote.locale, false)
    }

    // MARK: Колбэки Speech — `nonisolated`

    // Колбэки ниже система вызывает на своих очередях. Созданные внутри `@MainActor`-метода,
    // они унаследовали бы изоляцию главного актора, и Swift 6 остановил бы приложение
    // проверкой исполнителя. Поэтому они создаются в `nonisolated`-функциях и трогают
    // только `Sendable`-значения.

    /// Распознаватель и запрос создаются здесь же: они не `Sendable`, передавать их сюда
    /// с главного актора нельзя.
    private nonisolated static func recognize(fileAt url: URL, locale: Locale, onDevice: Bool) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw DictationUnavailability.languageNotSupported
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        // Задача распознавания нужна обработчику отмены; `SFSpeechRecognitionTask` не `Sendable`,
        // поэтому храним её под замком (`uncheckedState`: доступ только через замок).
        let task = OSAllocatedUnfairLock<SFSpeechRecognitionTask?>(uncheckedState: nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                let resume: @Sendable (Result<String, Error>) -> Void = { result in
                    let first = resumed.withLock { done in
                        defer { done = true }
                        return !done
                    }
                    if first { continuation.resume(with: result) }
                }
                let recognition = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        resume(RecognitionFailure.map(error))
                    } else if let result, result.isFinal {
                        resume(.success(result.bestTranscription.formattedString))
                    }
                }
                task.withLockUnchecked { $0 = recognition }
            }
        } onCancel: {
            task.withLockUnchecked { $0?.cancel() }
        }
    }

    private nonisolated static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }
}

/// Ошибки `SFSpeechRecognizer`, сведённые к тому, что важно для UI.
enum RecognitionFailure {
    static func map(_ error: any Error) -> Result<String, Error> {
        let error = error as NSError
        DictationLog.logger.info("Recognition ended: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
        switch (error.domain, error.code) {
        case ("kLSRErrorDomain", 201):
            return .failure(DictationUnavailability.dictationDisabled)
        case ("kAFAssistantErrorDomain", 1110), ("kLSRErrorDomain", 301):
            // «Речь не обнаружена» — не ошибка: просто нечего вставлять.
            return .success("")
        default:
            return .failure(RecognitionError(domain: error.domain, code: error.code))
        }
    }
}

/// Код ошибки распознавания без `userInfo` — его достаточно для лога и «не вышло».
struct RecognitionError: Error, Sendable {
    let domain: String
    let code: Int
}
