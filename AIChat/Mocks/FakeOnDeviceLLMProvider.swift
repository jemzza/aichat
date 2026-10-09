#if DEBUG
import Foundation
import Synchronization

/// «Модель на устройстве» для тестов и `-mockOnDeviceModel`: доступность переключается,
/// ответ — по сценарию `FakeLLMProvider`.
final class FakeOnDeviceLLMProvider: OnDeviceLLMProvider {
    let base: FakeLLMProvider
    private let available: Mutex<Bool>

    init(script: FakeLLMProvider.Script = .reply("An offline answer."), isAvailable: Bool = true) {
        base = FakeLLMProvider(script: script)
        available = Mutex(isAvailable)
    }

    var displayName: LocalizedStringResource { "Offline, on device" }

    var isAvailable: Bool { available.withLock { $0 } }

    var requests: [[LLMMessage]] { base.requests }

    func setAvailable(_ isAvailable: Bool) {
        available.withLock { $0 = isAvailable }
    }

    func streamReply(to messages: [LLMMessage]) -> AsyncThrowingStream<String, Error> {
        base.streamReply(to: messages)
    }
}
#endif
