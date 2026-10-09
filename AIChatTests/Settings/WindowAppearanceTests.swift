import Testing
import UIKit
@testable import AIChat

struct WindowAppearanceTests {
    @Test func systemFollowsTheSystemStyle() {
        #expect(AppearancePreference.light.interfaceStyle == .light)
        #expect(AppearancePreference.dark.interfaceStyle == .dark)
        #expect(AppearancePreference.system.interfaceStyle == .unspecified)
    }
}
