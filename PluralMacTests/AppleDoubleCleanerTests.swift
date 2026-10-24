import XCTest
@testable import PluralMac

final class AppleDoubleCleanerTests: XCTestCase {

    func testRemovesAppleDoubleFilesAndKeepsData() throws {
        let folder = try makeTemporaryDirectory(self)
        let logs = folder.appendingPathComponent("Library/Application Support/App/logs_dump")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for name in ["total.log", "._total.log", "._orphan"] {
            try Data(name.utf8).write(to: logs.appendingPathComponent(name))
        }
        try Data("db".utf8).write(to: folder.appendingPathComponent("._db.version"))
        try Data("db".utf8).write(to: folder.appendingPathComponent("db.version"))

        let removed = AppleDoubleCleaner.removeAppleDoubleFiles(in: folder)

        XCTAssertEqual(removed, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: logs.appendingPathComponent("total.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("db.version").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.appendingPathComponent("._total.log").path))
    }

    func testAPFSFolderNeedsNoCleanup() throws {
        // the temp folder sits on the APFS system volume
        XCTAssertFalse(AppleDoubleCleaner.needsCleanup(at: try makeTemporaryDirectory(self)))
    }

    func testFATVolumesNeedCleanup() {
        XCTAssertTrue(AppleDoubleCleaner.isAppleDoubleFileSystem("exfat"))
        XCTAssertTrue(AppleDoubleCleaner.isAppleDoubleFileSystem("msdos"))
        XCTAssertFalse(AppleDoubleCleaner.isAppleDoubleFileSystem("apfs"))
        XCTAssertFalse(AppleDoubleCleaner.isAppleDoubleFileSystem("hfs"))
    }

    func testLauncherCleansDataFolderOnFATVolumes() {
        let instance = AppInstance(name: "Work Profile", application: makeTestApplication(), dataPath: URL(fileURLWithPath: "/Volumes/External/Work"))

        let script = LauncherBuilder().script(for: instance, cleanAppleDouble: true)

        XCTAssertTrue(script.contains("/usr/bin/find '/Volumes/External/Work' -name '._*' -type f -delete"))
        XCTAssertFalse(LauncherBuilder().script(for: instance, cleanAppleDouble: false).contains("/usr/bin/find"))
    }
}
