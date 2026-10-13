import XCTest
import AppKit
@testable import PluralMac

final class LauncherIconTests: XCTestCase {

    private func solidImage(_ color: NSColor, size: Int = 32) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    private func centerColor(of image: NSImage) throws -> NSColor {
        var rect = NSRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        return try XCTUnwrap(color.usingColorSpace(.sRGB))
    }

    func testTintRotatesHue() throws {
        let red = solidImage(.red)

        let tinted = LauncherBuilder.tinted(red, hueDegrees: 120)

        let color = try centerColor(of: tinted)
        XCTAssertGreaterThan(color.greenComponent, color.redComponent)
        XCTAssertGreaterThan(color.greenComponent, color.blueComponent)
    }

    func testTintKeepsImageSize() {
        let tinted = LauncherBuilder.tinted(solidImage(.red, size: 64), hueDegrees: 200)
        XCTAssertEqual(tinted.size, NSSize(width: 64, height: 64))
    }

    func testInstancesSavedWithoutHueStillDecode() throws {
        let instance = AppInstance(name: "Work Profile", application: makeTestApplication())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try encode(instance)) as? [String: Any])
        json.removeValue(forKey: "launcherIconHue")
        json.removeValue(forKey: "launcherPath")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AppInstance.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertNil(decoded.launcherIconHue)
        XCTAssertNil(decoded.launcherPath)
    }

    func testHueRoundTripsThroughStorage() throws {
        var instance = AppInstance(name: "Work Profile", application: makeTestApplication())
        instance.launcherIconHue = 210

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AppInstance.self, from: try encode(instance))

        XCTAssertEqual(decoded.launcherIconHue, 210)
    }

    private func encode(_ instance: AppInstance) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(instance)
    }
}
