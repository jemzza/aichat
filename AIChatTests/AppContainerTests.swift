import Foundation
import Testing
@testable import AIChat

@MainActor
struct AppContainerTests {
    @Test func detectsUnitTestHost() {
        #expect(AppContainer.environment(for: .processInfo) == .unitTests)
    }

    @Test func keepsGivenEnvironment() {
        #expect(AppContainer(environment: .live).environment == .live)
    }
}
