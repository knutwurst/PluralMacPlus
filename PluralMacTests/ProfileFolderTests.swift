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
        // HOME stays the user's own, so the app still reaches the login keychain
        XCTAssertNil(instance.effectiveEnvironmentVariables["HOME"])
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

    func testMovingDataOfProfileAppMovesTheProfileFolder() throws {
        var instance = try makeElectronInstance()
        instance.profilePath = URL(fileURLWithPath: "/tmp/existing profile")
        XCTAssertEqual(instance.isolationRoot.path, "/tmp/existing profile")

        InstanceViewModel.repoint(&instance, from: instance.isolationRoot, to: URL(fileURLWithPath: "/Volumes/X/Work Profile"))

        XCTAssertEqual(instance.profilePath?.path, "/Volumes/X/Work Profile")
        XCTAssertEqual(instance.dataPath.path, "/tmp/pmp-home")
    }

    func testMovingSharedDataAndProfileFolderKeepsThemTogether() throws {
        var instance = try makeElectronInstance()
        instance.profilePath = instance.dataPath

        InstanceViewModel.repoint(&instance, from: instance.isolationRoot, to: URL(fileURLWithPath: "/Volumes/X/Work Profile"))

        XCTAssertEqual(instance.profilePath?.path, "/Volumes/X/Work Profile")
        XCTAssertEqual(instance.dataPath.path, "/Volumes/X/Work Profile")
    }

    func testDeletingDataNeverTouchesAChosenProfile() throws {
        var instance = try makeElectronInstance()
        XCTAssertEqual(InstanceViewModel.dataFolderToDelete(for: instance)?.path, "/tmp/pmp-home")

        instance.profilePath = instance.dataPath
        XCTAssertNil(InstanceViewModel.dataFolderToDelete(for: instance))

        instance.profilePath = URL(fileURLWithPath: "/tmp/existing profile")
        XCTAssertEqual(InstanceViewModel.dataFolderToDelete(for: instance)?.path, "/tmp/pmp-home")
    }
}
