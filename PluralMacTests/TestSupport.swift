import XCTest
@testable import PluralMac

/// Creates a unique temporary directory that is removed after the test.
func makeTemporaryDirectory(_ testCase: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PluralMacTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock {
        try? FileManager.default.removeItem(at: url)
    }
    return url
}

/// Builds a minimal fake .app bundle on disk and loads it as an Application.
func makeTestApplication() -> Application {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("PluralMacTests-FakeApp/ExampleApp.app")
    let macOS = bundleURL.appendingPathComponent("Contents/MacOS")
    try? FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleIdentifier": "com.example.testapp",
        "CFBundleName": "ExampleApp",
        "CFBundleExecutable": "ExampleApp",
        "CFBundlePackageType": "APPL",
    ]
    let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try! data.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    FileManager.default.createFile(atPath: macOS.appendingPathComponent("ExampleApp").path, contents: Data())
    return try! Application(from: bundleURL)
}
