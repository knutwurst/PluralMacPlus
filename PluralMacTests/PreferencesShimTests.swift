import XCTest
import ObjectiveC
@testable import PluralMac

/// Loads the bundled shim into the test process and checks where UserDefaults.standard writes.
final class PreferencesShimTests: XCTestCase {

    func testShimRedirectsStandardDefaultsToInstanceFile() throws {
        let shim = try XCTUnwrap(PreferencesIsolation.bundledShimURL, "shim not embedded in the app bundle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shim.path))

        // cfprefsd doesn't persist path domains inside the per-user temp folder (/var/folders),
        // so use a regular folder like a real instance data folder
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/PluralMacTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Library/Preferences/com.example.testapp.plist")
        setenv(PreferencesIsolation.fileEnvironmentKey, file.path, 1)
        defer { unsetenv(PreferencesIsolation.fileEnvironmentKey) }

        let handle = try XCTUnwrap(dlopen(shim.path, RTLD_NOW), String(cString: dlerror()))
        defer {
            // Undo the swizzle so other tests see the real standard defaults again
            let original = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard))!
            let replacement = class_getClassMethod(UserDefaults.self, NSSelectorFromString("pmp_standardUserDefaults"))!
            method_exchangeImplementations(original, replacement)
            dlclose(handle)
        }

        UserDefaults.standard.set("instance value", forKey: "pmpShimTest")
        UserDefaults.standard.synchronize()

        // The value lives in the instance domain, not in the host app's own defaults
        XCTAssertEqual(UserDefaults(suiteName: file.path)?.string(forKey: "pmpShimTest"), "instance value")
        XCTAssertNil(UserDefaults(suiteName: Bundle.main.bundleIdentifier!)?.string(forKey: "pmpShimTest"))

        // Another process sees the value through cfprefsd (which writes the plist itself later)
        let domain = file.deletingPathExtension().path
        XCTAssertEqual(try readDefault(domain: domain, key: "pmpShimTest"), "instance value")
    }

    private func readDefault(domain: String, key: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", domain, key]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
