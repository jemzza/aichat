import Foundation
import Testing
@testable import AIChat

@MainActor
struct NotificationServiceTests {
    private struct Harness {
        let settings: InMemorySettingsStore
        let scheduler: FakeNotificationScheduler
        let activity: FakeAppActivity
        let repository: InMemoryChatRepository
        let service: NotificationService
        let chat: Chat
    }

    private func makeHarness(notifyOnReply: Bool = true, notifyOnQueuedSent: Bool = true,
                             isAppActive: Bool = false,
                             authorization: NotificationAuthorization = .authorized) -> Harness {
        let chat = Chat(id: UUID(), title: "Trip ideas", createdAt: .now, updatedAt: .now)
        let repository = InMemoryChatRepository(
            chats: [chat],
            messages: [Message(chatId: chat.id, role: .user, text: "Hi", status: .sent, createdAt: .now)]
        )
        let settings = InMemorySettingsStore(notifyOnReply: notifyOnReply, notifyOnQueuedSent: notifyOnQueuedSent)
        let scheduler = FakeNotificationScheduler(status: authorization)
        let activity = FakeAppActivity(isAppActive: isAppActive)
        let service = NotificationService(settings: settings, scheduler: scheduler, activity: activity,
                                          repository: repository, plainText: { $0.replacingOccurrences(of: "**", with: "") })
        return Harness(settings: settings, scheduler: scheduler, activity: activity,
                       repository: repository, service: service, chat: chat)
    }

    // MARK: Политика

    @Test(arguments: [true, false], [true, false])
    func policyMatrix(isEnabled: Bool, isAppActive: Bool) {
        for authorization in [NotificationAuthorization.notDetermined, .authorized, .denied] {
            let expected = isEnabled && !isAppActive && authorization == .authorized
            #expect(NotificationPolicy.shouldNotify(isEnabled: isEnabled, isAppActive: isAppActive,
                                                    authorization: authorization) == expected,
                    "enabled: \(isEnabled), active: \(isAppActive), authorization: \(authorization)")
        }
    }

    // MARK: Готовый ответ

    @Test func finishedReplyNotifiesWithChatTitleAndReplyStart() async {
        let harness = makeHarness()

        await harness.service.replyDidFinish(chatId: harness.chat.id, text: "**Paris** is\nlovely in spring.")

        #expect(harness.scheduler.scheduled == [
            LocalNotification(title: "Trip ideas", body: "Paris is lovely in spring.", chatId: harness.chat.id),
        ])
    }

    @Test(arguments: [
        (false, false, NotificationAuthorization.authorized),
        (true, true, .authorized),
        (true, false, .denied),
        (true, false, .notDetermined),
    ])
    func replyIsNotNotifiedUnlessEnabledInBackgroundAndAllowed(
        isEnabled: Bool, isAppActive: Bool, authorization: NotificationAuthorization
    ) async {
        let harness = makeHarness(notifyOnReply: isEnabled, isAppActive: isAppActive, authorization: authorization)

        await harness.service.replyDidFinish(chatId: harness.chat.id, text: "Done")

        #expect(harness.scheduler.scheduled.isEmpty)
        // Сам сервис разрешение никогда не запрашивает.
        #expect(harness.scheduler.requestCount == 0)
    }

    @Test func replyInDeletedChatIsNotNotified() async throws {
        let harness = makeHarness()
        try await harness.repository.deleteChat(id: harness.chat.id)

        await harness.service.replyDidFinish(chatId: harness.chat.id, text: "Done")

        #expect(harness.scheduler.scheduled.isEmpty)
    }

    @Test func longReplyIsTruncated() {
        let text = String(repeating: "word ", count: 100)
        let preview = NotificationService.preview(text)
        #expect(preview.count == NotificationService.previewLength)
        #expect(preview.hasSuffix("…"))
        #expect(NotificationService.preview("  Short\n\n answer ") == "Short answer")
    }

    // MARK: Outbox

    @Test func queuedMessagesNotifyWithoutChat() async throws {
        let harness = makeHarness()

        await harness.service.queuedMessagesDidSend(count: 2)

        let notification = try #require(harness.scheduler.scheduled.first)
        #expect(harness.scheduler.scheduled.count == 1)
        #expect(notification.chatId == nil)
        #expect(notification.body.contains("2"))
    }

    @Test func queuedMessagesRespectTheirOwnToggleAndForeground() async {
        let off = makeHarness(notifyOnReply: true, notifyOnQueuedSent: false)
        await off.service.queuedMessagesDidSend(count: 1)
        #expect(off.scheduler.scheduled.isEmpty)

        let active = makeHarness(isAppActive: true)
        await active.service.queuedMessagesDidSend(count: 1)
        #expect(active.scheduler.scheduled.isEmpty)
    }

    // MARK: Нажатие

    @Test func chatIdIsReadFromUserInfo() {
        let id = UUID()
        #expect(UserNotificationScheduler.chatId(from: ["chatId": id.uuidString]) == id)
        #expect(UserNotificationScheduler.chatId(from: [:]) == nil)
        #expect(UserNotificationScheduler.chatId(from: ["chatId": "not-a-uuid"]) == nil)
    }

    @Test func navigationRequestIsTakenOnce() {
        let navigation = ChatNavigationRequests()
        let id = UUID()
        navigation.requestOpenChat(id: id)

        #expect(navigation.takePendingChatId() == id)
        #expect(navigation.takePendingChatId() == nil)
    }
}
