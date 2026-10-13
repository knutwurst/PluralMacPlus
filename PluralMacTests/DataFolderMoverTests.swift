import XCTest
@testable import PluralMac

final class DataFolderMoverTests: XCTestCase {

    private var root: URL!
    private var source: URL!
    private var targetParent: URL!
    private let mover = DataFolderMover()

    override func setUpWithError() throws {
        root = try makeTemporaryDirectory(self)
        source = root.appendingPathComponent("Data/1234")
        targetParent = root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetParent, withIntermediateDirectories: true)
        try Data("profile".utf8).write(to: source.appendingPathComponent("profile.db"))
    }

    func testMoveRelocatesContentsIntoFolderNamedAfterInstance() throws {
        let destination = try mover.move(from: source, toParent: targetParent, folderName: "Work Profile", instanceIsRunning: false)

        XCTAssertEqual(destination.path, targetParent.appendingPathComponent("Work Profile").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let moved = try String(contentsOf: destination.appendingPathComponent("profile.db"), encoding: .utf8)
        XCTAssertEqual(moved, "profile")
    }

    func testMoveRefusesWhileInstanceIsRunning() {
        XCTAssertThrowsError(try mover.move(from: source, toParent: targetParent, folderName: "X", instanceIsRunning: true)) { error in
            XCTAssertEqual(error as? DataFolderMover.MoveError, .instanceRunning)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMoveRefusesWhenDestinationExists() throws {
        try FileManager.default.createDirectory(at: targetParent.appendingPathComponent("X"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try mover.move(from: source, toParent: targetParent, folderName: "X", instanceIsRunning: false)) { error in
            XCTAssertEqual(error as? DataFolderMover.MoveError, .destinationExists(self.targetParent.appendingPathComponent("X")))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMoveRefusesDestinationInsideSource() {
        XCTAssertThrowsError(try mover.move(from: source, toParent: source, folderName: "X", instanceIsRunning: false)) { error in
            XCTAssertEqual(error as? DataFolderMover.MoveError, .destinationInsideSource)
        }
    }

    func testMoveWithoutExistingSourceOnlyReturnsNewPath() throws {
        let missing = root.appendingPathComponent("Data/never-launched")
        let destination = try mover.move(from: missing, toParent: targetParent, folderName: "Fresh", instanceIsRunning: false)

        XCTAssertEqual(destination.path, targetParent.appendingPathComponent("Fresh").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testMoveSanitizesFolderName() throws {
        let destination = try mover.move(from: source, toParent: targetParent, folderName: "Work/Private: 2", instanceIsRunning: false)
        XCTAssertEqual(destination.lastPathComponent, "Work-Private- 2")
    }
}
