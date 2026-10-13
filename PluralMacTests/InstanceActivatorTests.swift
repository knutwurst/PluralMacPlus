import XCTest
import AppKit
@testable import PluralMac

final class InstanceActivatorTests: XCTestCase {

    func testReopenEventTargetsGivenProcess() {
        let event = InstanceActivator.reopenEvent(for: 4242)

        XCTAssertEqual(event.eventClass, AEEventClass(kCoreEventClass))
        XCTAssertEqual(event.eventID, AEEventID(kAEReopenApplication))

        let target = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))
        XCTAssertEqual(target?.descriptorType, DescType(typeKernelProcessID))
        XCTAssertEqual(target?.data.withUnsafeBytes { $0.load(as: pid_t.self) }, 4242)
    }
}
