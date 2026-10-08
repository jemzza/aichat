import Foundation
import Testing
@testable import AIChat

struct MessageStatePresentationTests {
    private static let kinds: [ErrorKind] = [.offline, .rateLimited, .unauthorized, .forbidden, .server, .unknown]

    /// У каждой ошибки свой понятный текст и иконка — пользователь различает причины.
    @Test func everyErrorKindHasDistinctText() {
        let presentations = Self.kinds.map(MessageErrorPresentation.init(kind:))
        #expect(Set(presentations.map(\.title.key)).count == Self.kinds.count)
        #expect(Set(presentations.map(\.systemImage)).count == Self.kinds.count)
        #expect(presentations.allSatisfy { !$0.title.key.isEmpty })
    }

    @Test func bannerOnlyForFailedOrInterruptedReplies() {
        let chatId = UUID()
        func message(_ role: MessageRole, _ status: MessageStatus, failure: MessageFailure? = nil) -> Message {
            Message(chatId: chatId, role: role, text: "", status: status, failure: failure, createdAt: .now)
        }

        let failed = MessageErrorPresentation.forMessage(message(.assistant, .failed,
                                                                 failure: MessageFailure(kind: .forbidden)))
        #expect(failed?.title.key == MessageErrorPresentation(kind: .forbidden).title.key)
        #expect(MessageErrorPresentation.forMessage(message(.assistant, .failed))?.title.key
                == MessageErrorPresentation(kind: .unknown).title.key)
        #expect(MessageErrorPresentation.forMessage(message(.assistant, .interrupted))?.title.key
                == MessageErrorPresentation.interrupted.title.key)
        for status in [MessageStatus.streaming, .done, .cancelled] {
            #expect(MessageErrorPresentation.forMessage(message(.assistant, status)) == nil)
        }
        #expect(MessageErrorPresentation.forMessage(message(.user, .pending)) == nil)
    }

    @Test func retryCountdownRoundsUpAndEnds() {
        let now = Date(timeIntervalSince1970: 1_000)
        let failure = MessageFailure(kind: .rateLimited, retryAt: now.addingTimeInterval(29.2))

        #expect(MessageErrorPresentation.secondsUntilRetry(failure, now: now) == 30)
        #expect(MessageErrorPresentation.secondsUntilRetry(failure, now: now.addingTimeInterval(29)) == 1)
        #expect(MessageErrorPresentation.secondsUntilRetry(failure, now: now.addingTimeInterval(29.2)) == nil)
        #expect(MessageErrorPresentation.secondsUntilRetry(MessageFailure(kind: .rateLimited), now: now) == nil)
        #expect(MessageErrorPresentation.secondsUntilRetry(nil, now: now) == nil)
    }
}
