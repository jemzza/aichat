import SwiftUI

@main
struct AIChatApp: App {
    @State private var container: AppContainer
    @State private var screens: ChatDependencies?

    init() {
        let container = AppContainer(
            environment: AppContainer.environment(for: .processInfo),
            launchOptions: LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
        )
        _container = State(initialValue: container)
        _screens = State(initialValue: container.environment == .live ? container.makeChatDependencies() : nil)
    }

    var body: some Scene {
        WindowGroup {
            switch container.environment {
            case .live:
                if let screens {
                    RootView(dependencies: screens)
                } else {
                    PlaceholderView()
                }
            case .unitTests:
                EmptyView()
            }
        }
    }
}

private struct PlaceholderView: View {
    var body: some View {
        Text("AI Chat")
            .font(.largeTitle)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color("Background"))
    }
}
