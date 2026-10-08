import SwiftUI

@main
struct AIChatApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderView()
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
