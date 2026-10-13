import XCTest
import SwiftUI
@testable import PluralMac

final class SettingsViewTests: XCTestCase {

    /// The Settings scene creates `SettingsView()` without injecting any environment objects.
    func testSettingsViewRendersWithoutInjectedEnvironment() {
        let host = NSHostingView(rootView: SettingsView())
        host.frame = NSRect(x: 0, y: 0, width: 450, height: 300)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
}
