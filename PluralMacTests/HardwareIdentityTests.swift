import XCTest
@testable import PluralMac

final class HardwareIdentityTests: XCTestCase {

    private func makeInstance() -> AppInstance {
        AppInstance(name: "Work Profile", application: makeTestApplication(), dataPath: URL(fileURLWithPath: "/tmp/work"))
    }

    /// verbatim what a popular Flutter device-id plugin runs via "do shell script"
    private let pluginCommand = "ioreg -l | grep IOPlatformUUID | awk 'NR==1{print $4}' | sed 's/\\\"//g'"

    private func runShell(_ command: String, environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testRealHardwareIDByDefault() {
        let instance = makeInstance()
        XCTAssertNil(instance.hardwareIDOverride)
        XCTAssertNil(instance.effectiveEnvironmentVariables[HardwareIdentity.environmentKey])
    }

    func testSeparateIDIsStablePerInstance() {
        let instance = makeInstance()
        XCTAssertEqual(HardwareIdentity.separateID(for: instance.id), HardwareIdentity.separateID(for: instance.id))
        XCTAssertNotEqual(HardwareIdentity.separateID(for: instance.id), HardwareIdentity.separateID(for: UUID()))
        XCTAssertNotEqual(HardwareIdentity.separateID(for: instance.id), instance.id)
    }

    func testPluginCommandSeesSeparateID() throws {
        var instance = makeInstance()
        let separate = HardwareIdentity.separateID(for: instance.id)
        instance.hardwareIDOverride = separate

        let output = try runShell(pluginCommand, environment: instance.effectiveEnvironmentVariables)

        XCTAssertEqual(output, separate.uuidString)
    }

    func testPluginCommandSeesRealIDWithoutOverride() throws {
        let real = try runShell(pluginCommand, environment: [:])
        let output = try runShell(pluginCommand, environment: makeInstance().effectiveEnvironmentVariables)

        XCTAssertFalse(real.isEmpty)
        XCTAssertEqual(output, real)
    }

    func testOtherIoregOutputIsUntouched() throws {
        var instance = makeInstance()
        instance.hardwareIDOverride = HardwareIdentity.separateID(for: instance.id)
        let command = "ioreg -rd1 -c IOPlatformExpertDevice | grep -c IOPlatformSerialNumber"

        XCTAssertEqual(try runShell(command, environment: instance.effectiveEnvironmentVariables),
                       try runShell(command, environment: [:]))
    }

    func testLauncherPassesFunctionUnchanged() throws {
        var instance = makeInstance()
        instance.hardwareIDOverride = HardwareIdentity.separateID(for: instance.id)
        let function = try XCTUnwrap(instance.effectiveEnvironmentVariables[HardwareIdentity.environmentKey])

        // the launcher single-quotes KEY=value; the shell has to pass it through byte for byte
        let quoted = LauncherBuilder.shellQuote("\(HardwareIdentity.environmentKey)=\(function)")
        XCTAssertTrue(LauncherBuilder().script(for: instance).contains("--env \(quoted)"))
        XCTAssertEqual(try runShell("printf %s \(quoted)", environment: [:]), "\(HardwareIdentity.environmentKey)=\(function)")
    }
}
