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

    /// Без launch-аргументов фейки не подключаются.
    @Test func usesRealImplementationsByDefault() {
        #expect(AppContainer(environment: .live).launchOptions == .none)
        #expect(AppContainer(environment: .live).launchOptions.usesMocks == false)
    }
}

struct LaunchOptionsTests {
    @Test func noArgumentsMeansNoMocks() {
        #expect(LaunchOptions(arguments: []) == .none)
        #expect(LaunchOptions(arguments: ["/path/AIChat", "-NSDoubleLocalizedStrings", "YES"]).usesMocks == false)
    }

    /// Так приложение реально запускается в этом процессе — фейков быть не должно.
    @Test func currentProcessArgumentsDoNotEnableMocks() {
        #expect(LaunchOptions(arguments: ProcessInfo.processInfo.arguments).usesMocks == false)
    }

    @Test func parsesEachFlag() {
        let options = LaunchOptions(arguments: ["app", "-mockData", "-mockOffline", "-mockSlowStream"])
        #expect(options.useMockData)
        #expect(options.forceOffline)
        #expect(options.slowStream)
        #expect(options.mockError == nil)
        #expect(options.usesMocks)
    }

    @Test(arguments: [
        ("429", ErrorKind.rateLimited), ("401", .unauthorized), ("403", .forbidden),
        ("500", .server), ("offline", .offline), ("teapot", .unknown),
    ])
    func parsesMockError(value: String, kind: ErrorKind) {
        #expect(LaunchOptions(arguments: ["app", "-mockError", value]).mockError == kind)
    }

    @Test func mockErrorWithoutValueIsUnknown() {
        #expect(LaunchOptions(arguments: ["app", "-mockError"]).mockError == .unknown)
    }
}
