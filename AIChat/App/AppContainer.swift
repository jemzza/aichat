import Foundation

/// Корень композиции: создаёт и держит зависимости приложения.
/// Единственный «глобальный» объект — живёт в `AIChatApp` и передаётся дальше через инициализаторы.
@MainActor
final class AppContainer {
    enum Environment: Sendable, Equatable {
        /// Обычный запуск: реальная БД, сеть, мониторинг соединения.
        case live
        /// Приложение запущено как хост для unit-тестов: ничего не поднимаем,
        /// тесты собирают свои зависимости сами (in-memory БД, фейки).
        case unitTests
    }

    let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    static func environment(for processInfo: ProcessInfo) -> Environment {
        processInfo.environment["XCTestConfigurationFilePath"] == nil ? .live : .unitTests
    }
}
