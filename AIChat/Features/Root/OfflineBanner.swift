import SwiftUI

/// Ненавязчивый баннер под верхней панелью, когда нет сети.
struct OfflineBanner: View {
    var body: some View {
        Label("No connection", systemImage: "wifi.slash")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.appSurface, in: .capsule)
            .overlay { Capsule().strokeBorder(.secondary.opacity(0.2)) }
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("Light") { OfflineBanner().padding().background(.appBackground) }
#Preview("Dark") { OfflineBanner().padding().background(.appBackground).preferredColorScheme(.dark) }
#endif
