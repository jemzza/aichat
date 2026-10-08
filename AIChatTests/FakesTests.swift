import Foundation
import Testing
@testable import AIChat

struct FakeLLMProviderTests {
    @Test func streamsTextTokenByToken() async {
        let text = "Hello **world**\nsecond line"
        let provider = FakeLLMProvider(script: .reply(text, tokenDelay: .zero))
        let request = [LLMMessage(role: .user, content: "Hi")]

        let result = await collect(provider.streamReply(to: request))

        #expect(result.text == text)
        #expect(result.error == nil)
        #expect(FakeLLMProvider.tokens(of: text).count == 4)
        #expect(provider.requests == [request])
    }

    @Test func failsAfterPartialText() async {
        let error = LLMError(kind: .rateLimited, retryAfter: .seconds(12))
        let provider = FakeLLMProvider(script: .fail(error, partialText: "Half ", tokenDelay: .zero))

        let result = await collect(provider.streamReply(to: []))

        #expect(result.text == "Half ")
        #expect(result.error as? LLMError == error)
    }

    /// Отмена завершает «висящий» поток; итерация кончается без ошибки,
    /// а потребитель видит отмену через `Task.isCancelled`.
    @Test func cancellationStopsHangingStream() async {
        let provider = FakeLLMProvider(script: .hang)
        let task = Task {
            let result = await collect(provider.streamReply(to: []))
            return (result, Task.isCancelled)
        }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let (result, wasCancelled) = await task.value

        #expect(result.text.isEmpty)
        #expect(result.error == nil)
        #expect(wasCancelled)
    }

    /// Отмена посреди ответа: уже полученный текст остаётся у потребителя.
    /// Отменяем сразу после первого токена, а не по таймеру: под параллельной
    /// нагрузкой таймер не гарантирует, что токен успел прийти.
    @Test func cancellationKeepsReceivedText() async {
        let provider = FakeLLMProvider(script: .reply("one two three four five", tokenDelay: .milliseconds(40)))
        let task = Task {
            var text = ""
            var error: (any Error)?
            do {
                for try await token in provider.streamReply(to: []) {
                    text += token
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            } catch let caught {
                error = caught
            }
            return (text, error, Task.isCancelled)
        }

        let (text, error, wasCancelled) = await task.value

        #expect(text == "one ")
        #expect(error == nil)
        #expect(wasCancelled)
    }
}

struct FakeConnectivityMonitorTests {
    @Test func emitsCurrentValueThenOnlyChanges() async throws {
        let monitor = FakeConnectivityMonitor(isOnline: true)
        var iterator = monitor.updates().makeAsyncIterator()
        #expect(await iterator.next() == true)

        monitor.setOnline(true)   // без изменений — не эмитится
        monitor.setOnline(false)
        monitor.setOnline(true)

        #expect(await iterator.next() == false)
        #expect(await iterator.next() == true)
        #expect(monitor.isOnline)
    }

    @Test func supportsSeveralSubscribers() async throws {
        let monitor = FakeConnectivityMonitor(isOnline: true)
        let first = monitor.updates()
        let second = monitor.updates()

        monitor.setOnline(false)

        #expect(try await firstValue(of: first) { !$0 } == false)
        #expect(try await firstValue(of: second) { !$0 } == false)
    }
}

struct PreviewDataTests {
    @Test func coversEveryMessageStatus() {
        let statuses = Set(PreviewData.messages.map(\.status))
        #expect(statuses == [.pending, .sent, .streaming, .done, .cancelled, .failed, .interrupted])
    }

    @Test func seedsRepository() async throws {
        let repository = PreviewData.repository()
        let chats = try await firstValue(of: repository.observeChats())
        #expect(chats.count == PreviewData.chats.count)
    }
}
