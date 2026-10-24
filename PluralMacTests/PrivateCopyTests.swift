import XCTest
import AppKit
@testable import PluralMac

final class PrivateCopyTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTemporaryDirectory(self)
    }

    /// hardened fake app: real Mach-O, restricted entitlements, provisioning profile, asset-catalog icon, localized name
    private func makeHardenedApp(version: String = "4.0.6") throws -> URL {
        let app = folder.appendingPathComponent("Example.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources/en.lproj"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/Example"))

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.hardened",
            "CFBundleExecutable": "Example",
            "CFBundlePackageType": "APPL",
            "CFBundleName": "Example",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1",
            "CFBundleIconName": "AppIcon",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("\"CFBundleName\" = \"Beispiel\";\n\"NSHumanReadableCopyright\" = \"x\";\n".utf8)
            .write(to: contents.appendingPathComponent("Resources/en.lproj/InfoPlist.strings"))
        try Data("profile".utf8).write(to: contents.appendingPathComponent("embedded.provisionprofile"))

        let entitlements: [String: Any] = [
            "com.apple.security.device.camera": true,
            "keychain-access-groups": ["TEAM.com.example"],
            "com.apple.developer.team-identifier": "TEAM",
            "com.apple.application-identifier": "TEAM.com.example.hardened",
        ]
        let entitlementsFile = folder.appendingPathComponent("entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: entitlementsFile)
        try run("/usr/bin/codesign", ["--sign", "-", "--force", "--options", "runtime", "--entitlements", entitlementsFile.path, app.path])
        return app
    }

    private func makeInstance(app: URL) throws -> AppInstance {
        AppInstance(name: "Work Profile", application: try Application(from: app), dataPath: folder.appendingPathComponent("data"))
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func info(_ app: URL) throws -> [String: Any] {
        try XCTUnwrap(NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
    }

    func testCopyCarriesInstanceNameAndOwnIcon() throws {
        let original = try makeHardenedApp()
        let instance = try makeInstance(app: original)

        let copy = try PrivateCopyBuilder(clonesDirectory: folder.appendingPathComponent("Clones"))
            .build(for: instance, icon: NSWorkspace.shared.icon(forFile: original.path))

        XCTAssertEqual(copy.path.lastPathComponent, "Work Profile.app")
        let plist = try info(copy.path)
        XCTAssertEqual(plist["CFBundleName"] as? String, "Work Profile")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Work Profile")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.example.hardened")
        XCTAssertNil(plist["CFBundleIconName"])
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, PrivateCopyBuilder.iconFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path.appendingPathComponent("Contents/Resources/\(PrivateCopyBuilder.iconFileName).icns").path))
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, false)

        let strings = try String(contentsOf: copy.path.appendingPathComponent("Contents/Resources/en.lproj/InfoPlist.strings"), encoding: .utf8)
        XCTAssertFalse(strings.contains("CFBundleName"))
        XCTAssertTrue(strings.contains("NSHumanReadableCopyright"))
    }

    func testCopyIsResignedWithoutHardenedRuntimeAndRestrictedEntitlements() throws {
        let original = try makeHardenedApp()
        let instance = try makeInstance(app: original)
        XCTAssertFalse(PreferencesIsolation.allowsLibraryInjection(appAt: original))

        let copy = try PrivateCopyBuilder(clonesDirectory: folder.appendingPathComponent("Clones")).build(for: instance, icon: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path.appendingPathComponent("Contents/embedded.provisionprofile").path))
        XCTAssertFalse(PreferencesIsolation.usesHardenedRuntime(appAt: copy.path))
        XCTAssertTrue(PreferencesIsolation.allowsLibraryInjection(appAt: copy.path))
        XCTAssertEqual(try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", copy.path.path]), 0)

        // entitlements sit on the Mach-O; the bundle's main executable is the start script
        let entitlements = PreferencesIsolation.entitlements(appAt: copy.path.appendingPathComponent("Contents/MacOS/Example"))
        XCTAssertEqual(entitlements["com.apple.security.device.camera"] as? Bool, true)
        XCTAssertNil(entitlements["keychain-access-groups"])
        XCTAssertNil(entitlements["com.apple.developer.team-identifier"])
        XCTAssertNil(entitlements["com.apple.application-identifier"])
    }

    func testCopyRecordsOriginalVersionAndDetectsUpdates() throws {
        let original = try makeHardenedApp(version: "4.0.6")
        var instance = try makeInstance(app: original)
        instance.privateCopy = try PrivateCopyBuilder(clonesDirectory: folder.appendingPathComponent("Clones")).build(for: instance, icon: nil)

        XCTAssertFalse(PrivateCopyBuilder.isOutdated(instance))

        let plistURL = original.appendingPathComponent("Contents/Info.plist")
        let plist = try XCTUnwrap(NSMutableDictionary(contentsOf: plistURL))
        plist["CFBundleShortVersionString"] = "4.0.7"
        plist.write(to: plistURL, atomically: true)

        XCTAssertTrue(PrivateCopyBuilder.isOutdated(instance))
    }

    func testCopyStartsThroughScriptThatSetsUpTheInstance() throws {
        let original = try makeHardenedApp()
        var instance = try makeInstance(app: original)
        instance.hardwareIDOverride = HardwareIdentity.separateID(for: instance.id)
        instance.separatePreferences = true

        let copy = try PrivateCopyBuilder(clonesDirectory: folder.appendingPathComponent("Clones")).build(for: instance, icon: nil)

        let plist = try info(copy.path)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, PrivateCopyBuilder.startScriptName)
        XCTAssertEqual(plist[PrivateCopyBuilder.originalExecutableKey] as? String, "Example")
        let script = try String(contentsOf: copy.path.appendingPathComponent("Contents/MacOS/\(PrivateCopyBuilder.startScriptName)"), encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.contains("export HOME=\(LauncherBuilder.shellQuote(instance.dataPath.path))"))
        XCTAssertTrue(script.contains("export DYLD_INSERT_LIBRARIES="))
        XCTAssertTrue(script.contains("export -f ioreg"))
        XCTAssertTrue(script.hasSuffix("exec \"${0%/*}/Example\" \"$@\"\n"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: copy.path.appendingPathComponent("Contents/MacOS/Example").path))
        XCTAssertEqual(try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", copy.path.path]), 0)
    }

    /// runs the start script up to the exec and checks what the real binary would see
    func testStartScriptHandsEnvironmentAndDeviceIDToTheApp() throws {
        var instance = try makeInstance(app: try makeHardenedApp())
        instance.hardwareIDOverride = HardwareIdentity.separateID(for: instance.id)
        let script = LauncherBuilder().copyStartScript(for: instance, executableName: "Example", cleanAppleDouble: false)
            .replacingOccurrences(of: "exec \"${0%/*}/Example\" \"$@\"", with: "echo \"HOME=$HOME\"; ioreg -l | grep IOPlatformUUID | awk 'NR==1{print $4}' | sed 's/\\\"//g'")
            .replacingOccurrences(of: PrivateCopyBuilder.lsregisterPath, with: "/usr/bin/true")
        let file = folder.appendingPathComponent("start.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [file.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        XCTAssertTrue(output.contains("HOME=\(instance.dataPath.path)"), output)
        XCTAssertTrue(output.contains(instance.hardwareIDOverride!.uuidString), output)
    }

    /// older copies signed the real binary against Info.plist; updating them has to re-sign it
    func testUpdatingCopyFromEarlierVersionKeepsValidSignature() throws {
        let original = try makeHardenedApp()
        var instance = try makeInstance(app: original)
        let builder = PrivateCopyBuilder(clonesDirectory: folder.appendingPathComponent("Clones"))
        instance.privateCopy = try builder.build(for: instance, icon: nil)

        // fake an old-style copy: real binary as main executable, signed as the bundle
        let copy = try XCTUnwrap(instance.privateCopy).path
        let plistURL = copy.appendingPathComponent("Contents/Info.plist")
        let plist = try XCTUnwrap(NSMutableDictionary(contentsOf: plistURL))
        plist["CFBundleExecutable"] = "Example"
        plist.removeObject(forKey: PrivateCopyBuilder.originalExecutableKey)
        plist.write(to: plistURL, atomically: true)
        try FileManager.default.removeItem(at: copy.appendingPathComponent("Contents/MacOS/\(PrivateCopyBuilder.startScriptName)"))
        XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", copy.path]), 0)

        instance.privateCopy = try builder.updateIdentity(of: instance, icon: nil)

        XCTAssertEqual(try info(copy)["CFBundleExecutable"] as? String, PrivateCopyBuilder.startScriptName)
        XCTAssertEqual(try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", copy.path]), 0)
    }

    func testDetectsBrokenCopySignature() throws {
        let original = try makeHardenedApp()
        var instance = try makeInstance(app: original)
        instance.privateCopy = try PrivateCopyBuilder(clonesDirectory: folder.appendingPathComponent("Clones")).build(for: instance, icon: nil)
        XCTAssertTrue(PrivateCopyBuilder.isSignatureValid(instance.privateCopy!.path))

        let plistURL = instance.privateCopy!.path.appendingPathComponent("Contents/Info.plist")
        let plist = try XCTUnwrap(NSMutableDictionary(contentsOf: plistURL))
        plist["CFBundleName"] = "tampered"
        plist.write(to: plistURL, atomically: true)

        XCTAssertFalse(PrivateCopyBuilder.isSignatureValid(instance.privateCopy!.path))
    }

    func testCopyNeedsRefreshWhenIconColorOrNameChanged() throws {
        let original = try makeHardenedApp()
        var instance = try makeInstance(app: original)
        instance.launcherIconHue = 120
        var copy = try PrivateCopyBuilder(clonesDirectory: folder.appendingPathComponent("Clones")).build(for: instance, icon: nil)
        copy.iconHue = instance.launcherIconHue
        instance.privateCopy = copy
        XCTAssertFalse(PrivateCopyBuilder.needsRefresh(instance))

        instance.launcherIconHue = 240
        XCTAssertTrue(PrivateCopyBuilder.needsRefresh(instance))

        instance.launcherIconHue = 120
        instance.name = "Renamed"
        XCTAssertTrue(PrivateCopyBuilder.needsRefresh(instance))
    }

    /// macOS caches icons like a squirrel caches nuts; only a new bundle mtime makes it look again
    func testBuildingAndUpdatingMarkTheBundleAsChanged() throws {
        let original = try makeHardenedApp()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: original.path)
        var instance = try makeInstance(app: original)
        let builder = PrivateCopyBuilder(clonesDirectory: folder.appendingPathComponent("Clones"))
        let modified = { (url: URL) in try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) }

        instance.privateCopy = try builder.build(for: instance, icon: nil)
        XCTAssertGreaterThan(try modified(instance.privateCopy!.path), Date().addingTimeInterval(-60))

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: instance.privateCopy!.path.path)
        instance.launcherIconHue = 90
        instance.privateCopy = try builder.updateIdentity(of: instance, icon: nil)
        XCTAssertGreaterThan(try modified(instance.privateCopy!.path), Date().addingTimeInterval(-60))
    }

    func testInstanceLaunchesAndMatchesTheCopy() throws {
        let original = try makeHardenedApp()
        var instance = try makeInstance(app: original)
        XCTAssertEqual(instance.launchAppPath, original)

        instance.privateCopy = try PrivateCopyBuilder(clonesDirectory: folder.appendingPathComponent("Clones")).build(for: instance, icon: nil)

        XCTAssertEqual(instance.launchAppPath, instance.privateCopy?.path)
        XCTAssertTrue(LauncherBuilder().script(for: instance).contains("open -n -a \(LauncherBuilder.shellQuote(instance.privateCopy!.path.path))"))

        let process = RunningProcess(pid: 9, bundleURL: instance.privateCopy!.path, home: instance.dataPath.path)
        XCTAssertEqual(RunningInstanceMatcher.match(instances: [instance], processes: [process]), [instance.id: 9])
    }

    func testRebuildingIdentityRenamesCopy() throws {
        let original = try makeHardenedApp()
        var instance = try makeInstance(app: original)
        let builder = PrivateCopyBuilder(clonesDirectory: folder.appendingPathComponent("Clones"))
        instance.privateCopy = try builder.build(for: instance, icon: nil)

        instance.rename(to: "Second Profile")
        instance.privateCopy = try builder.updateIdentity(of: instance, icon: nil)

        let copy = try XCTUnwrap(instance.privateCopy)
        XCTAssertEqual(copy.path.lastPathComponent, "Second Profile.app")
        XCTAssertEqual(try info(copy.path)["CFBundleName"] as? String, "Second Profile")
        XCTAssertEqual(try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", copy.path.path]), 0)
    }
}

final class TestHostIsolationTests: XCTestCase {
    /// the test host is PluralMac Plus itself and must never load (or touch) the user's instances
    func testTestHostIsDetected() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
    }
}
