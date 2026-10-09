import SwiftUI

@main
struct AIChatApp: App {
    @State private var container = AppContainer(
        environment: AppContainer.environment(for: .processInfo),
        launchOptions: LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
    )

    var body: some Scene {
        WindowGroup {
            switch container.environment {
            case .live:
                LiveRoot(container: container)
                    .windowAppearance(container.settings.appearance)
            case .unitTests:
                EmptyView()
            }
        }
    }
}

/// Запуск: открываем базу (асинхронно), потом показываем экраны и запускаем `ChatService`.
private struct LiveRoot: View {
    let container: AppContainer

    private enum Phase {
        case loading
        case ready(ChatDependencies, ChatService<ContinuousClock>)
        case failed
    }

    @State private var phase = Phase.loading
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch phase {
            case .loading:
                Color.appBackground.ignoresSafeArea()
            case let .ready(dependencies, service):
                RootView(dependencies: dependencies)
                    // Сеть и запуск → outbox; живёт столько же, сколько окно.
                    .task { await service.run() }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { service.appDidBecomeActive() }
                    }
            case .failed:
                ContentUnavailableView {
                    Label("Couldn't open chat history", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Please restart the app.")
                }
                .background(.appBackground)
            }
        }
        .task {
            guard case .loading = phase else { return }
            do {
                let screens = try await container.makeScreens()
                phase = .ready(screens.dependencies, screens.service)
            } catch {
                phase = .failed
            }
        }
    }
}
