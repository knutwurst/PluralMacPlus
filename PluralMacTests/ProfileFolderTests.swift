import XCTest
@testable import PluralMac

final class ProfileFolderTests: XCTestCase {

    private func makeElectronInstance() throws -> AppInstance {
        var instance = AppInstance(name: "Work Profile", application: makeTestApplication(), dataPath: URL(fileURLWithPath: "/tmp/pmp-home"))
        instance.isolationMethodOverride = .userDataDir
        return instance
    }

    func testUserDataDirDefaultsToDataFolder() throws {
        let instance = try makeElectronInstance()
        XCTAssertTrue(instance.effectiveCommandLineArguments.contains("--user-data-dir=/tmp/pmp-home"))
    }

    func testUserDataDirUsesProfileFolder() throws {
        var instance = try makeElectronInstance()
        instance.profilePath = URL(fileURLWithPath: "/tmp/existing profile")

        XCTAssertTrue(instance.effectiveCommandLineArguments.contains("--user-data-dir=/tmp/existing profile"))
        XCTAssertFalse(instance.effectiveCommandLineArguments.contains("--user-data-dir=/tmp/pmp-home"))
        // HOME stays the PluralMac Plus data folder
        XCTAssertEqual(instance.effectiveEnvironmentVariables["HOME"], "/tmp/pmp-home")
    }

    func testLauncherDoesNotTouchProfileFolder() throws {
        var instance = try makeElectronInstance()
        instance.profilePath = URL(fileURLWithPath: "/tmp/existing profile")
        let script = LauncherBuilder().script(for: instance, cleanAppleDouble: true)

        XCTAssertTrue(script.contains("'--user-data-dir=/tmp/existing profile'"))
        XCTAssertFalse(script.contains("mkdir -p '/tmp/existing profile'"))
        XCTAssertFalse(script.contains("find '/tmp/existing profile'"))
    }

    func testPrivateCopyIsNotOfferedForProfileBasedApps() throws {
        XCTAssertFalse(try makeElectronInstance().canUsePrivateCopy)
        var native = AppInstance(name: "Native", application: makeTestApplication())
        native.isolationMethodOverride = .homeRedirection
        XCTAssertTrue(native.canUsePrivateCopy)
    }
}
