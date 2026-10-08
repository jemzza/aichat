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
                PlaceholderView()
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
