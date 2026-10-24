import XCTest
@testable import PluralMac

final class PreferencesIsolationTests: XCTestCase {

    private func makeInstance(dataPath: URL = URL(fileURLWithPath: "/tmp/work")) -> AppInstance {
        AppInstance(name: "Work Profile", application: makeTestApplication(), dataPath: dataPath)
    }

    func testSharedPreferencesByDefault() {
        let environment = makeInstance().effectiveEnvironmentVariables
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(environment[PreferencesIsolation.fileEnvironmentKey])
    }

    func testSeparatePreferencesInjectShimAndFile() {
        var instance = makeInstance()
        instance.separatePreferences = true

        let environment = instance.effectiveEnvironmentVariables

        XCTAssertEqual(environment["DYLD_INSERT_LIBRARIES"], PreferencesIsolation.installedShimURL.path)
        XCTAssertEqual(environment[PreferencesIsolation.fileEnvironmentKey],
                       "/tmp/work/Library/Preferences/\(instance.targetBundleIdentifier).pluralmacplus.plist")
    }

    /// cfprefsd mirrors writes into the real app domain if the file is named like the bundle ID
    func testPreferencesFileIsNotNamedLikeTheAppDomain() {
        let file = PreferencesIsolation.preferencesFile(for: makeInstance())
        XCTAssertNotEqual(file.deletingPathExtension().lastPathComponent, makeInstance().targetBundleIdentifier)
    }

    func testSeedMovesOnFromLegacyInstanceFile() throws {
        let folder = try makeTemporaryDirectory(self)
        let shared = folder.appendingPathComponent("shared.plist")
        try Data("shared".utf8).write(to: shared)
        let instance = makeInstance(dataPath: folder.appendingPathComponent("data"))
        let legacy = PreferencesIsolation.legacyPreferencesFile(for: instance)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacy)

        try PreferencesIsolation.seedPreferences(for: instance, from: shared)

        XCTAssertEqual(try String(contentsOf: PreferencesIsolation.preferencesFile(for: instance), encoding: .utf8), "legacy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testDetectsHardenedRuntime() throws {
        let folder = try makeTemporaryDirectory(self)
        let app = try copyFakeApp(to: folder.appendingPathComponent("Hardened.app"))
        try codesign(app, hardened: true)
        XCTAssertTrue(PreferencesIsolation.usesHardenedRuntime(appAt: app))
    }

    func testPlainSignatureIsNotHardened() throws {
        let folder = try makeTemporaryDirectory(self)
        let app = try copyFakeApp(to: folder.appendingPathComponent("Plain.app"))
        try codesign(app, hardened: false)
        XCTAssertFalse(PreferencesIsolation.usesHardenedRuntime(appAt: app))
    }

    func testSeedCopiesSharedPreferencesWhenInstanceHasNone() throws {
        let folder = try makeTemporaryDirectory(self)
        let shared = folder.appendingPathComponent("shared.plist")
        try Data("shared".utf8).write(to: shared)
        let instance = makeInstance(dataPath: folder.appendingPathComponent("data"))

        try PreferencesIsolation.seedPreferences(for: instance, from: shared)

        let file = PreferencesIsolation.preferencesFile(for: instance)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "shared")
    }

    func testSeedKeepsExistingInstancePreferences() throws {
        let folder = try makeTemporaryDirectory(self)
        let shared = folder.appendingPathComponent("shared.plist")
        try Data("shared".utf8).write(to: shared)
        let instance = makeInstance(dataPath: folder.appendingPathComponent("data"))
        let file = PreferencesIsolation.preferencesFile(for: instance)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("own".utf8).write(to: file)

        try PreferencesIsolation.seedPreferences(for: instance, from: shared)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "own")
    }

    func testUnhardenedAppAllowsInjection() throws {
        let folder = try makeTemporaryDirectory(self)
        let app = try copyFakeApp(to: folder.appendingPathComponent("Plain.app"))
        try codesign(app, hardened: false)
        XCTAssertTrue(PreferencesIsolation.allowsLibraryInjection(appAt: app))
    }

    func testHardenedAppBlocksInjection() throws {
        let folder = try makeTemporaryDirectory(self)
        let app = try copyFakeApp(to: folder.appendingPathComponent("Hardened.app"))
        try codesign(app, hardened: true)
        XCTAssertFalse(PreferencesIsolation.allowsLibraryInjection(appAt: app))
    }

    func testHardenedAppWithDyldEntitlementsAllowsInjection() throws {
        let folder = try makeTemporaryDirectory(self)
        let app = try copyFakeApp(to: folder.appendingPathComponent("Allowed.app"))
        try codesign(app, hardened: true, entitlements: [
            "com.apple.security.cs.allow-dyld-environment-variables": true,
            "com.apple.security.cs.disable-library-validation": true,
        ], in: folder)
        XCTAssertTrue(PreferencesIsolation.allowsLibraryInjection(appAt: app))
    }

    func testHardenedAppWithOnlyDyldEntitlementBlocksInjection() throws {
        let folder = try makeTemporaryDirectory(self)
        let app = try copyFakeApp(to: folder.appendingPathComponent("HalfAllowed.app"))
        try codesign(app, hardened: true, entitlements: [
            "com.apple.security.cs.allow-dyld-environment-variables": true,
        ], in: folder)
        XCTAssertFalse(PreferencesIsolation.allowsLibraryInjection(appAt: app))
    }

    /// needs a real Mach-O, otherwise codesign can't embed entitlements
    private func copyFakeApp(to destination: URL) throws -> URL {
        let source = makeTestApplication().path
        try FileManager.default.copyItem(at: source, to: destination)
        let executable = destination.appendingPathComponent("Contents/MacOS/ExampleApp")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        return destination
    }

    private func codesign(_ app: URL, hardened: Bool, entitlements: [String: Any]? = nil, in folder: URL? = nil) throws {
        var arguments = ["--sign", "-", "--force"] + (hardened ? ["--options", "runtime"] : [])
        if let entitlements, let folder {
            let file = folder.appendingPathComponent("entitlements-\(UUID().uuidString).plist")
            try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: file)
            arguments += ["--entitlements", file.path]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments + [app.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
