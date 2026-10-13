import XCTest
@testable import PluralMac

final class CustomDataPathTests: XCTestCase {

    func testNewInstanceUsesExplicitDataPath() {
        let custom = URL(fileURLWithPath: "/Volumes/External/ExampleApp")
        let instance = AppInstance(name: "ExampleApp", application: makeTestApplication(), dataPath: custom)
        XCTAssertEqual(instance.dataPath, custom)
    }

    func testNewInstanceWithoutExplicitDataPathUsesDataDirectory() {
        let dataDirectory = URL(fileURLWithPath: "/tmp/pluralmac-data")
        let instance = AppInstance(name: "ExampleApp", application: makeTestApplication(), dataDirectory: dataDirectory, dataPath: nil)
        XCTAssertEqual(instance.dataPath, dataDirectory.appendingPathComponent(instance.id.uuidString))
    }

    func testInstanceUsingDataPathFindsOwner() {
        let shared = URL(fileURLWithPath: "/Volumes/External/ExampleApp")
        let owner = AppInstance(name: "A", application: makeTestApplication(), dataPath: shared)
        let other = AppInstance(name: "B", application: makeTestApplication())

        let found = AppInstance.instance(usingDataPath: URL(fileURLWithPath: "/Volumes/External/ExampleApp/"), in: [other, owner])
        XCTAssertEqual(found?.id, owner.id)
    }

    func testInstanceUsingDataPathIsNilForUnusedPath() {
        let other = AppInstance(name: "B", application: makeTestApplication())
        XCTAssertNil(AppInstance.instance(usingDataPath: URL(fileURLWithPath: "/Volumes/External/Free"), in: [other]))
    }
}
