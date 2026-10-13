import XCTest
@testable import PluralMac

final class IsolationEnvironmentTests: XCTestCase {

    private func makeInstance() -> AppInstance {
        AppInstance(name: "Work Profile", application: makeTestApplication(), dataPath: URL(fileURLWithPath: "/Volumes/External/Work"))
    }

    /// Foundation ignores HOME; CFFIXED_USER_HOME redirects NSHomeDirectory, Caches, Application Support, HTTPStorages
    func testEnvironmentFixesFoundationHomeToDataFolder() {
        let environment = makeInstance().effectiveEnvironmentVariables
        XCTAssertEqual(environment["CFFIXED_USER_HOME"], "/Volumes/External/Work")
        XCTAssertEqual(environment["HOME"], "/Volumes/External/Work")
    }

    func testLauncherScriptSetsFixedUserHome() {
        let script = LauncherBuilder().script(for: makeInstance())
        XCTAssertTrue(script.contains("--env 'CFFIXED_USER_HOME=/Volumes/External/Work'"))
    }

    func testLauncherIsUpToDateRightAfterBuilding() throws {
        let folder = try makeTemporaryDirectory(self)
        let instance = makeInstance()
        let launcher = try LauncherBuilder().build(for: instance, in: folder)

        XCTAssertTrue(LauncherBuilder().isUpToDate(launcher, for: instance))
    }

    func testLauncherIsOutdatedWhenInstanceChanged() throws {
        let folder = try makeTemporaryDirectory(self)
        var instance = makeInstance()
        let launcher = try LauncherBuilder().build(for: instance, in: folder)

        instance.commandLineArguments = ["--new"]

        XCTAssertFalse(LauncherBuilder().isUpToDate(launcher, for: instance))
    }
}
