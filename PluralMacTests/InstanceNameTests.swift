import XCTest
@testable import PluralMac

final class InstanceNameTests: XCTestCase {

    func testValidatedNameTrimsWhitespace() {
        XCTAssertEqual(AppInstance.validatedName("  Work Profile  "), "Work Profile")
    }

    func testValidatedNameRejectsBlankInput() {
        XCTAssertNil(AppInstance.validatedName(""))
        XCTAssertNil(AppInstance.validatedName("   \n"))
    }

    func testRenameKeepsDataPath() {
        var instance = AppInstance(name: "Old", application: makeTestApplication())
        let dataPath = instance.dataPath
        instance.rename(to: "New")
        XCTAssertEqual(instance.name, "New")
        XCTAssertEqual(instance.dataPath, dataPath)
    }
}
