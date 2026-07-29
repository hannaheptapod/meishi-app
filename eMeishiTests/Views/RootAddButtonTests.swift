import Testing
import UIKit
@testable import eMeishi

@MainActor
struct RootAddButtonTests {
    @Test func usesSharedProminentGlassAppearance() throws {
        let button = RootAddButtonAppearance.makeButton()
        let configuration = try #require(button.configuration)

        #expect(configuration.image != nil)
        #expect(configuration.cornerStyle == .capsule)
        #expect(configuration.baseBackgroundColor == UIColor(named: "AccentColor"))
        #expect(configuration.baseForegroundColor == .white)
        #expect(button.accessibilityIdentifier == "cardAddButton")
    }
}
