import XCTest
@testable import PluralMac

final class LaunchOptionsTests: XCTestCase {

    // MARK: - Environment variables

    func testAcceptsValidVariableName() {
        XCTAssertNil(LaunchOptions.problem(withVariableName: "MY_FLAG_2"))
    }

    func testRejectsEmptyOrInvalidVariableNames() {
        XCTAssertNotNil(LaunchOptions.problem(withVariableName: ""))
        XCTAssertNotNil(LaunchOptions.problem(withVariableName: "2FAST"))
        XCTAssertNotNil(LaunchOptions.problem(withVariableName: "WITH SPACE"))
        XCTAssertNotNil(LaunchOptions.problem(withVariableName: "A=B"))
    }

    func testRejectsVariablesThatIsolationOverrides() {
        for name in ["HOME", "CFFIXED_USER_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"] {
            XCTAssertNotNil(LaunchOptions.problem(withVariableName: name), name)
        }
    }

    func testCustomVariableReachesEffectiveEnvironment() {
        var instance = AppInstance(name: "Work Profile", application: makeTestApplication())
        instance.environmentVariables = ["MY_FLAG": "1"]
        XCTAssertEqual(instance.effectiveEnvironmentVariables["MY_FLAG"], "1")
    }

    // MARK: - Arguments

    func testNormalizedArgumentTrimsWhitespace() {
        XCTAssertEqual(LaunchOptions.normalizedArgument("  --flag  "), "--flag")
    }

    func testNormalizedArgumentRejectsBlank() {
        XCTAssertNil(LaunchOptions.normalizedArgument("   "))
    }

    func testNormalizedArgumentKeepsInnerSpaces() {
        XCTAssertEqual(LaunchOptions.normalizedArgument("--title=two words"), "--title=two words")
    }

    // MARK: - Ordering

    func testMovingInstanceChangesOrder() {
        let ids = (0..<4).map { _ in UUID() }
        let instances = ids.map { id -> AppInstance in
            var instance = AppInstance(name: id.uuidString, application: makeTestApplication())
            instance = instance.withID(id)
            return instance
        }

        let reordered = InstanceOrdering.move(instances, from: IndexSet(integer: 3), to: 0)

        XCTAssertEqual(reordered.map(\.id), [ids[3], ids[0], ids[1], ids[2]])
    }
}

private extension AppInstance {
    /// Test helper: same instance with a fixed id
    func withID(_ id: UUID) -> AppInstance {
        let data = try! JSONEncoder.iso.encode(self)
        var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["id"] = id.uuidString
        return try! JSONDecoder.iso.decode(AppInstance.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
