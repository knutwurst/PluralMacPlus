import XCTest
@testable import PluralMac

final class SmokeTests: XCTestCase {
    func testDefaultBaseDirectoryIsInLibrary() {
        XCTAssertTrue(AppInstance.defaultBaseDirectory.path.hasSuffix("Library/PluralMac"))
    }
}
