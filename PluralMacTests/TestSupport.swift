import XCTest
@testable import PluralMac

/// Unique temp folder, removed again in teardown
func makeTemporaryDirectory(_ testCase: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PluralMacTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock {
        try? FileManager.default.removeItem(at: url)
    }
    return url
}

/// Minimal fake .app, shared by all tests at a fixed temp path
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
