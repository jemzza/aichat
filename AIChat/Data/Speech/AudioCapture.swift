import AVFoundation

/// Микрофон для диктовки: `AVAudioEngine` + настройка `AVAudioSession`.
/// Буферы отдаются обработчику прямо с аудиопотока и нигде не сохраняются.
///
/// `@unchecked Sendable`: обработчик tap-а вызывается на аудиопотоке и трогает только
/// `converter`/`outputFormat`, которые задаются в `start` до установки tap-а и дальше
/// не меняются; `start`/`stop` вызываются с главного актора.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    /// - Parameters:
    ///   - format: формат, который ждёт распознаватель; `nil` — формат микрофона как есть.
    ///   - onBuffer: буфер (в `format`) и громкость 0…1; вызывается на аудиопотоке.
    func start(format: AVAudioFormat?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        if let format, format != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: format)
            outputFormat = format
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [self] buffer, _ in
            guard let converted = convert(buffer) else { return }
            onBuffer(converted, Self.level(of: buffer))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        converter = nil
        outputFormat = nil
        // Музыка других приложений снова звучит в полную громкость.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let outputFormat else { return buffer }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        // Блок ввода объявлен `@Sendable`, но `convert` вызывает его синхронно, на этом же
        // потоке и до своего возврата — общих данных между потоками здесь нет.
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        return status == .error ? nil : output
    }

    /// Среднеквадратичная громкость первого канала, приведённая к 0…1 (−50…0 дБ).
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(max((decibels + 50) / 50, 0), 1)
    }
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
