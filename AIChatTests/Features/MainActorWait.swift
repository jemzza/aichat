import Foundation

/// Ждёт, пока условие на главном акторе станет истинным (ViewModel получают данные
/// из наблюдения асинхронно).
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimeoutError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}
