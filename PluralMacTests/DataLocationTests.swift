import XCTest
@testable import PluralMac

final class DataLocationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PluralMacTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testBaseDirectoryFallsBackToLibraryDataWhenUnset() {
        let expected = AppInstance.defaultBaseDirectory.appendingPathComponent("Data")
        XCTAssertEqual(DataLocation.baseDirectory(defaults: defaults), expected)
    }

    func testBaseDirectoryFallsBackWhenSettingIsBlank() {
        defaults.set("   ", forKey: DataLocation.defaultsKey)
        let expected = AppInstance.defaultBaseDirectory.appendingPathComponent("Data")
        XCTAssertEqual(DataLocation.baseDirectory(defaults: defaults), expected)
    }

    func testBaseDirectoryUsesCustomSetting() {
        defaults.set("/Volumes/External/PluralMac", forKey: DataLocation.defaultsKey)
        XCTAssertEqual(
            DataLocation.baseDirectory(defaults: defaults).path,
            "/Volumes/External/PluralMac"
        )
    }

    func testBaseDirectoryExpandsTilde() {
        defaults.set("~/PluralMacData", forKey: DataLocation.defaultsKey)
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("PluralMacData").path
        XCTAssertEqual(DataLocation.baseDirectory(defaults: defaults).path, expected)
    }

    func testNewInstanceStoresDataUnderGivenDataDirectory() {
        let dataDirectory = URL(fileURLWithPath: "/Volumes/External/PluralMac")
        let instance = AppInstance(name: "Work Profile", application: makeTestApplication(), dataDirectory: dataDirectory)
        XCTAssertEqual(
            instance.dataPath,
            dataDirectory.appendingPathComponent(instance.id.uuidString)
        )
    }

    func testUnmountedVolumeIsReportedForMissingVolume() {
        let volume = "/Volumes/PluralMacMissing-\(UUID().uuidString)"
        let path = URL(fileURLWithPath: "\(volume)/Data/abc")
        XCTAssertEqual(DataLocation.unmountedVolume(for: path)?.path, volume)
    }

    func testUnmountedVolumeIsNilForPathsOutsideVolumes() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertNil(DataLocation.unmountedVolume(for: path))
    }

    func testUnmountedVolumeIsNilForMountedVolume() {
        // the boot volume always shows up in /Volumes
        let mounted = try! FileManager.default.contentsOfDirectory(atPath: "/Volumes").first!
        let path = URL(fileURLWithPath: "/Volumes/\(mounted)/does-not-exist-\(UUID().uuidString)")
        XCTAssertNil(DataLocation.unmountedVolume(for: path))
    }
}
