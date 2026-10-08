import Foundation
import Testing
@testable import AIChat

struct GreetingTests {
    @Test(arguments: [
        (0, Greeting.evening), (4, .evening), (5, .morning), (11, .morning),
        (12, .afternoon), (16, .afternoon), (17, .evening), (23, .evening),
    ])
    func greetingByHour(hour: Int, expected: Greeting) {
        #expect(Greeting(hour: hour) == expected)
    }

    @Test func greetingUsesCalendarTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 09:30 UTC.
        let date = Date(timeIntervalSince1970: 9.5 * 3600)
        #expect(Greeting(date: date, calendar: calendar) == .morning)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 18:30 в Токио.
        #expect(Greeting(date: date, calendar: calendar) == .evening)
    }

    @Test func suggestionsAreThreeToFourWithUniqueIds() {
        #expect((3...4).contains(Suggestion.all.count))
        #expect(Set(Suggestion.all.map(\.id)).count == Suggestion.all.count)
    }
}

@MainActor
struct ConnectivityStatusTests {
    @Test func followsMonitor() async throws {
        let monitor = FakeConnectivityMonitor(isOnline: true)
        let status = ConnectivityStatus(monitor: monitor)
        let observation = Task { await status.observe() }
        defer { observation.cancel() }
        #expect(status.isOnline)

        monitor.setOnline(false)
        try await waitUntil { !status.isOnline }
        monitor.setOnline(true)
        try await waitUntil { status.isOnline }
    }

    @Test func startsWithCurrentValue() {
        #expect(!ConnectivityStatus(monitor: FakeConnectivityMonitor(isOnline: false)).isOnline)
    }
}
