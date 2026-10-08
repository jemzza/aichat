import AVFoundation
import Foundation

/// Озвучка на `AVSpeechSynthesizer`: на устройстве, работает без сети.
@MainActor
final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing {
    private let synthesizer = AVSpeechSynthesizer()
    private let audioSession: AVAudioSession
    private var playback = SpeechPlayback.idle {
        didSet {
            guard playback != oldValue else { return }
            for continuation in continuations.values { continuation.yield(playback) }
        }
    }
    private var continuations: [UUID: AsyncStream<SpeechPlayback>.Continuation] = [:]
    /// Какое высказывание сейчас читается: `didCancel` прерванного приходит уже после
    /// старта нового и не должен сбросить состояние в `idle`.
    private var currentUtterance: AVSpeechUtterance?

    init(audioSession: AVAudioSession = .sharedInstance()) {
        self.audioSession = audioSession
        super.init()
        synthesizer.delegate = self
    }

    func playbackUpdates() -> AsyncStream<SpeechPlayback> {
        let (stream, continuation) = AsyncStream<SpeechPlayback>.makeStream()
        let id = UUID()
        continuation.yield(playback)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    func speak(_ text: String, messageId: UUID) {
        guard !text.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        let utterance = AVSpeechUtterance(string: text)
        // Скорость и голос из «Устного контента», если пользователь их настроил.
        utterance.prefersAssistiveTechnologySettings = true
        if let voice = Self.voice(for: text) { utterance.voice = voice }

        activateAudioSession()
        currentUtterance = utterance
        playback = .speaking(messageId: messageId)
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking || playback != .idle else { return }
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    private func finish() {
        playback = .idle
        // Другие приложения (музыка) снова звучат в полную громкость.
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func activateAudioSession() {
        // Без сессии озвучка молчит при беззвучном режиме; `.duckOthers` приглушает музыку.
        // Ошибка не критична: синтезатор всё равно попробует говорить.
        try? audioSession.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? audioSession.setActive(true)
    }

    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let infos = voices.map { voice in
            VoiceInfo(identifier: voice.identifier, language: voice.language, quality: VoiceInfo.Quality(voice.quality))
        }
        guard let chosen = VoiceSelection.voice(for: text, among: infos, userLocale: .current) else { return nil }
        return AVSpeechSynthesisVoice(identifier: chosen.identifier)
    }
}

extension SystemSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    // Делегат вызывается не с главного потока; `AVSpeechUtterance` не `Sendable`,
    // поэтому передаём на главный актор его идентичность, а не сам объект.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id: id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id: id) }
    }

    private func finished(id: ObjectIdentifier) {
        guard let currentUtterance, ObjectIdentifier(currentUtterance) == id else { return }
        self.currentUtterance = nil
        finish()
    }
}

private extension VoiceInfo.Quality {
    init(_ quality: AVSpeechSynthesisVoiceQuality) {
        switch quality {
        case .premium: self = .premium
        case .enhanced: self = .enhanced
        default: self = .standard
        }
    }
}
