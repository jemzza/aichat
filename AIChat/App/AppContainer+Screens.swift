import Foundation

extension AppContainer {
    /// Зависимости экранов. Реальных репозитория и `ChatService` ещё нет (шаги 1.3, 3.2),
    /// поэтому пока экраны собираются только с `-mockData` (фейки из `Mocks/`);
    /// без аргумента остаётся заглушка — фейки в обычный запуск не попадают.
    /// `-mockOffline` вместе с `-mockData` — сеть «нет» (баннер, `pending`).
    func makeChatDependencies() -> ChatDependencies? {
        #if DEBUG
        if launchOptions.useMockData {
            return .preview(connectivity: FakeConnectivityMonitor(isOnline: !launchOptions.forceOffline))
        }
        #endif
        return nil
    }
}
