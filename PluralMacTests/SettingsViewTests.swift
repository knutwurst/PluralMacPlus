import XCTest
import SwiftUI
@testable import PluralMac

final class SettingsViewTests: XCTestCase {

    /// the Settings scene creates SettingsView() with no environment objects injected
    func testSettingsViewRendersWithoutInjectedEnvironment() {
        let host = NSHostingView(rootView: SettingsView())
        host.frame = NSRect(x: 0, y: 0, width: 450, height: 300)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
}
