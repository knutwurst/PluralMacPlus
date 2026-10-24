import XCTest
@testable import PluralMac

final class RegressionFixTests: XCTestCase {

    func testNotesSurviveSaving() throws {
        var instance = AppInstance(name: "Work Profile", application: makeTestApplication())
        instance.notes = "the one with the old account"

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AppInstance.self, from: encoder.encode(instance))

        XCTAssertEqual(decoded.notes, "the one with the old account")
    }

    // used to be String.hashValue, which changes with every launch
    func testIconCacheKeyIsStableForAppsWithoutBundleID() {
        let app = URL(fileURLWithPath: "/tmp/does-not-exist/Some Tool.app")
        let key = IconCache.cacheKey(for: app)

        XCTAssertEqual(key, IconCache.cacheKey(for: app))
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(key.count, 32)
        XCTAssertNotEqual(key, IconCache.cacheKey(for: URL(fileURLWithPath: "/tmp/does-not-exist/Other Tool.app")))
    }

    // a duplicate bundle ID in compatibility.json used to trap at launch
    func testDuplicateCompatibilityEntriesKeepTheFirst() throws {
        let json = """
        [
          {"bundleIdentifier": "com.example.App", "name": "First", "appType": "electron", "compatibilityLevel": "full",
           "isolationMethod": "userDataDir", "recommendedArguments": [], "notes": "", "testedVersion": "1"},
          {"bundleIdentifier": "com.example.app", "name": "Second", "appType": "electron", "compatibilityLevel": "full",
           "isolationMethod": "userDataDir", "recommendedArguments": [], "notes": "", "testedVersion": "1"}
        ]
        """
        let entries = try JSONDecoder().decode([CompatibilityDatabase.CompatibilityEntry].self, from: Data(json.utf8))

        let index = CompatibilityDatabase.index(entries)

        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index["com.example.app"]?.name, "First")
    }
}
