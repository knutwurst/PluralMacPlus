import XCTest
@testable import PluralMac

final class LauncherBuilderTests: XCTestCase {

    private var folder: URL!
    private let builder = LauncherBuilder()

    override func setUpWithError() throws {
        folder = try makeTemporaryDirectory(self)
    }

    private func makeInstance(name: String = "Work Profile", dataPath: URL = URL(fileURLWithPath: "/tmp/plural data/work")) -> AppInstance {
        AppInstance(name: name, application: makeTestApplication(), dataPath: dataPath)
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(LauncherBuilder.shellQuote("it's"), "'it'\\''s'")
    }

    func testScriptOpensNewInstanceOfTargetWithIsolatedHome() {
        let instance = makeInstance()
        let script = builder.script(for: instance)

        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("/usr/bin/open -n -a \(LauncherBuilder.shellQuote(instance.targetAppPath.path))"))
        XCTAssertTrue(script.contains("--env 'HOME=/tmp/plural data/work'"))
        XCTAssertFalse(script.contains("--args"))
    }

    func testScriptPassesCommandLineArguments() {
        var instance = makeInstance()
        instance.commandLineArguments = ["--flag", "two words"]
        let script = builder.script(for: instance)

        XCTAssertTrue(script.contains("--args '--flag' 'two words'"))
    }

    func testScriptChecksVolumeForExternalDataFolder() {
        let instance = makeInstance(dataPath: URL(fileURLWithPath: "/Volumes/External/Work"))
        let script = builder.script(for: instance)

        XCTAssertTrue(script.contains("[ ! -d '/Volumes/External' ]"))
    }

    func testBuildCreatesExecutableBundleNamedAfterInstance() throws {
        let instance = makeInstance()
        let launcher = try builder.build(for: instance, in: folder)

        XCTAssertEqual(launcher.lastPathComponent, "Work Profile.app")

        let plistData = try Data(contentsOf: launcher.appendingPathComponent("Contents/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleName"] as? String, "Work Profile")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(plist[LauncherBuilder.instanceIDKey] as? String, instance.id.uuidString)

        let executable = launcher.appendingPathComponent("Contents/MacOS/\(plist["CFBundleExecutable"] as! String)")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    }

    func testBuildReplacesExistingLauncherOfSameInstance() throws {
        var instance = makeInstance()
        _ = try builder.build(for: instance, in: folder)
        instance.commandLineArguments = ["--updated"]

        let launcher = try builder.build(for: instance, in: folder)

        let script = try String(contentsOf: launcher.appendingPathComponent("Contents/MacOS/launcher"), encoding: .utf8)
        XCTAssertTrue(script.contains("--updated"))
    }

    func testBuildRefusesToOverwriteForeignApp() throws {
        let foreign = folder.appendingPathComponent("Work Profile.app/Contents")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)

        XCTAssertThrowsError(try builder.build(for: makeInstance(), in: folder)) { error in
            XCTAssertEqual(error as? LauncherBuilder.LauncherError, .appAlreadyExists(self.folder.appendingPathComponent("Work Profile.app")))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    func testIsLauncherRecognizesOnlyOwnInstance() throws {
        let instance = makeInstance()
        let launcher = try builder.build(for: instance, in: folder)

        XCTAssertTrue(LauncherBuilder.isLauncher(at: launcher, for: instance.id))
        XCTAssertFalse(LauncherBuilder.isLauncher(at: launcher, for: UUID()))
    }
}
