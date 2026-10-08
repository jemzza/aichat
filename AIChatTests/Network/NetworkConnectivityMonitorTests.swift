import Testing
@testable import AIChat

/// Сам `NWPathMonitor` в тесте не управляем — проверяем только контракт потока.
struct NetworkConnectivityMonitorTests {
    @Test func updatesStartWithCurrentValue() async throws {
        let monitor = NetworkConnectivityMonitor()
        let first = try await firstValue(of: monitor.updates())
        #expect(first == monitor.isOnline)
    }

    @Test func eachSubscriberGetsItsOwnStream() async throws {
        let monitor = NetworkConnectivityMonitor()
        async let a = firstValue(of: monitor.updates())
        async let b = firstValue(of: monitor.updates())
        let (first, second) = try await (a, b)
        #expect(first == second)
    }
}
