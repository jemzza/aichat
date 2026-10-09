import Foundation

/// Корень композиции: создаёт и держит зависимости приложения.
/// Единственный «глобальный» объект — живёт в `AIChatApp` и передаётся дальше через инициализаторы.
///
/// По умолчанию — только реальные реализации. Фейки из `Mocks/` подключаются
/// исключительно через `LaunchOptions` (DEBUG launch-аргументы, шаг 3.5).
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
    let launchOptions: LaunchOptions
    let groqConfiguration: GroqConfiguration
    /// Создаются сразу, без базы: тема нужна окну с первого кадра.
    let settings: any SettingsStoring

    init(
        environment: Environment,
        launchOptions: LaunchOptions = .none,
        groqConfiguration: GroqConfiguration = .bundled(),
        settings: any SettingsStoring = UserDefaultsSettingsStore()
    ) {
        self.environment = environment
        self.launchOptions = launchOptions
        self.groqConfiguration = groqConfiguration
        self.settings = settings
    }

    static func environment(for processInfo: ProcessInfo) -> Environment {
        processInfo.environment["XCTestConfigurationFilePath"] == nil ? .live : .unitTests
    }
}
