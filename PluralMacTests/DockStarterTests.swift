import XCTest
import AppKit
@testable import PluralMac

/// Dock starter: tiny bundle with the instance's name and icon that execs the original binary
final class DockStarterTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTemporaryDirectory(self)
    }

    private func makeElectronApp() throws -> URL {
        let app = folder.appendingPathComponent("Example.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/Example"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.electron",
            "CFBundleExecutable": "Example",
            "CFBundlePackageType": "APPL",
            "CFBundleName": "Example",
            "CFBundleShortVersionString": "8.0.0",
            "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func makeInstance(app: URL) throws -> AppInstance {
        var instance = AppInstance(name: "Work Profile", application: try Application(from: app), dataPath: folder.appendingPathComponent("data"))
        instance.isolationMethodOverride = .userDataDir
        instance.profilePath = folder.appendingPathComponent("profile")
        return instance
    }

    private func builder() -> PrivateCopyBuilder {
        PrivateCopyBuilder(clonesDirectory: folder.appendingPathComponent("Clones"))
    }

    private func info(_ app: URL) throws -> [String: Any] {
        try XCTUnwrap(NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
    }

    private func verifies(_ bundle: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func testArgumentIsolatedAppsGetAStarter() throws {
        let instance = try makeInstance(app: try makeElectronApp())
        XCTAssertTrue(PrivateCopyBuilder.usesStarter(instance))

        var other = instance
        other.isolationMethodOverride = .homeRedirection
        XCTAssertFalse(PrivateCopyBuilder.usesStarter(other))
    }

    func testStarterIsOwnBundleThatExecsTheOriginalBinary() throws {
        let original = try makeElectronApp()
        let originalInfo = try Data(contentsOf: original.appendingPathComponent("Contents/Info.plist"))
        var instance = try makeInstance(app: original)
        instance.commandLineArguments = ["--flag"]

        let starter = try builder().build(for: instance, icon: NSWorkspace.shared.icon(forFile: original.path))
        instance.privateCopy = starter

        XCTAssertTrue(starter.isStarter)
        let plist = try info(starter.path)
        XCTAssertEqual(plist["CFBundleName"] as? String, "Work Profile")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.knutwurst.pluralmacplus.starter.\(instance.id.uuidString.lowercased())")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, PrivateCopyBuilder.startScriptName)
        XCTAssertEqual(plist["LSUIElement"] as? Bool, false)
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, PrivateCopyBuilder.iconFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: starter.path.appendingPathComponent("Contents/Resources/\(PrivateCopyBuilder.iconFileName).icns").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: starter.path.appendingPathComponent("Contents/MacOS/Example").path))

        let script = try String(contentsOf: starter.path.appendingPathComponent("Contents/MacOS/\(PrivateCopyBuilder.startScriptName)"), encoding: .utf8)
        let binary = LauncherBuilder.shellQuote(original.appendingPathComponent("Contents/MacOS/Example").path)
        let profile = LauncherBuilder.shellQuote("--user-data-dir=\(instance.profilePath!.path)")
        XCTAssertTrue(script.hasSuffix("exec \(binary) '--flag' \(profile) \"$@\"\n"), script)
        // no HOME redirect, or the app loses the login keychain
        XCTAssertFalse(script.contains("HOME="), script)
        // own bundle ID, nothing to re-register
        XCTAssertFalse(script.contains("lsregister"))

        XCTAssertTrue(try verifies(starter.path))
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("Contents/Info.plist")), originalInfo)
        XCTAssertFalse(PrivateCopyBuilder.needsRefresh(instance))
    }

    func testStarterNeverCountsAsOutdated() throws {
        let original = try makeElectronApp()
        var instance = try makeInstance(app: original)
        instance.privateCopy = try builder().build(for: instance, icon: nil)

        let plistURL = original.appendingPathComponent("Contents/Info.plist")
        let plist = try XCTUnwrap(NSMutableDictionary(contentsOf: plistURL))
        plist["CFBundleShortVersionString"] = "9.0.0"
        plist.write(to: plistURL, atomically: true)

        XCTAssertFalse(PrivateCopyBuilder.isOutdated(instance))
    }

    func testRenamingRewritesStarterInPlace() throws {
        var instance = try makeInstance(app: try makeElectronApp())
        instance.privateCopy = try builder().build(for: instance, icon: nil)

        instance.rename(to: "Second Profile")
        XCTAssertTrue(PrivateCopyBuilder.needsRefresh(instance))
        instance.privateCopy = try builder().updateIdentity(of: instance, icon: nil)

        let starter = try XCTUnwrap(instance.privateCopy)
        XCTAssertTrue(starter.isStarter)
        XCTAssertEqual(starter.path.lastPathComponent, "Second Profile.app")
        XCTAssertEqual(try info(starter.path)["CFBundleName"] as? String, "Second Profile")
        XCTAssertTrue(try verifies(starter.path))
        XCTAssertFalse(PrivateCopyBuilder.needsRefresh(instance))
    }

    /// the starter execs the original binary, so the process shows up as the original app
    func testRunningStarterProcessMatchesInstance() throws {
        var instance = try makeInstance(app: try makeElectronApp())
        instance.privateCopy = try builder().build(for: instance, icon: nil)

        XCTAssertEqual(instance.launchAppPath, instance.privateCopy?.path)
        XCTAssertEqual(instance.codeAppPath, instance.targetAppPath)

        let process = RunningProcess(pid: 5, bundleURL: instance.targetAppPath, home: NSHomeDirectory(),
                                     arguments: ["--user-data-dir=\(instance.profilePath!.path)"])
        XCTAssertEqual(RunningInstanceMatcher.match(instances: [instance], processes: [process]), [instance.id: 5])

        let normal = RunningProcess(pid: 6, bundleURL: instance.targetAppPath, home: NSHomeDirectory())
        XCTAssertTrue(RunningInstanceMatcher.match(instances: [instance], processes: [normal]).isEmpty)
    }

    /// copy and starter pass the arguments themselves, the launcher must not add them twice
    func testLauncherDoesNotRepeatArgumentsOfStarter() throws {
        var instance = try makeInstance(app: try makeElectronApp())
        instance.privateCopy = try builder().build(for: instance, icon: nil)

        let script = LauncherBuilder().script(for: instance, cleanAppleDouble: false)
        XCTAssertFalse(script.contains("--args"), script)
        XCTAssertFalse(script.contains("lsregister"), script)
    }

    /// a redirected HOME hides the login keychain, so profile-argument apps keep the real one
    func testArgumentIsolatedAppsKeepTheirHome() throws {
        var instance = try makeInstance(app: try makeElectronApp())
        instance.hardwareIDOverride = HardwareIdentity.separateID(for: instance.id)

        XCTAssertFalse(instance.redirectsHome)
        XCTAssertEqual(instance.isolationRoot, instance.profilePath)
        let env = instance.effectiveEnvironmentVariables
        XCTAssertNil(env["HOME"])
        XCTAssertNil(env["CFFIXED_USER_HOME"])
        XCTAssertNil(env["XDG_CONFIG_HOME"])
        XCTAssertNotNil(env[HardwareIdentity.environmentKey])

        instance.isolationMethodOverride = .homeRedirection
        XCTAssertTrue(instance.redirectsHome)
        XCTAssertEqual(instance.effectiveEnvironmentVariables["HOME"], instance.dataPath.path)
    }

    func testProfileArgumentInstancesMatchByArgumentOnly() throws {
        let instance = try makeInstance(app: try makeElectronApp())
        let other = RunningProcess(pid: 7, bundleURL: instance.targetAppPath, home: instance.dataPath.path,
                                   arguments: ["--user-data-dir=/somewhere/else"])
        let own = RunningProcess(pid: 8, bundleURL: instance.targetAppPath, home: NSHomeDirectory(),
                                 arguments: ["--flag", "--user-data-dir=\(instance.profilePath!.path)"])

        XCTAssertEqual(RunningInstanceMatcher.match(instances: [instance], processes: [other, own]), [instance.id: 8])
    }

    func testLauncherForArgumentIsolatedAppDoesNotCreateTheProfile() throws {
        let instance = try makeInstance(app: try makeElectronApp())
        let script = LauncherBuilder().script(for: instance, cleanAppleDouble: false)
        XCTAssertFalse(script.contains("mkdir"), script)
        XCTAssertFalse(script.contains("HOME="), script)
    }

    func testCopiesSavedBeforeStartersDecodeAsClones() throws {
        let json = #"{"path":"file:///tmp/A.app","originalVersion":"1 (1)","createdAt":0}"#
        let copy = try JSONDecoder().decode(PrivateAppCopy.self, from: Data(json.utf8))
        XCTAssertFalse(copy.isStarter)
    }
}
