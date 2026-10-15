import XCTest
@testable import PluralMac

final class RunningInstanceDiscoveryTests: XCTestCase {

    // MARK: - Process arguments parsing

    /// Builds a KERN_PROCARGS2 buffer: argc, exec path, padding, argv, env
    private func procArgsBuffer(argv: [String], env: [String]) -> [UInt8] {
        var argc = Int32(argv.count)
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/Applications/Example.app/Contents/MacOS/Example".utf8) + [0, 0, 0]
        for value in argv + env {
            bytes += Array(value.utf8) + [0]
        }
        return bytes
    }

    func testParseSeparatesArgumentsFromEnvironment() {
        let buffer = procArgsBuffer(
            argv: ["/Applications/Example.app/Contents/MacOS/Example", "--flag"],
            env: ["HOME=/Volumes/External/Work", "XDG_CONFIG_HOME=/Volumes/External/Work/.config"]
        )

        let environment = ProcessEnvironment.parse(procArgs: buffer)

        XCTAssertEqual(environment?["HOME"], "/Volumes/External/Work")
        XCTAssertEqual(environment?["XDG_CONFIG_HOME"], "/Volumes/External/Work/.config")
        XCTAssertNil(environment?["--flag"])
    }

    func testParseReadsArgumentsWithoutExecutable() {
        let buffer = procArgsBuffer(argv: ["/Applications/Example.app/Contents/MacOS/Example", "--user-data-dir=/a b"], env: ["HOME=/x"])
        XCTAssertEqual(ProcessEnvironment.parseArguments(procArgs: buffer), ["--user-data-dir=/a b"])
    }

    func testReadsArgumentsOfOwnProcess() {
        XCTAssertEqual(ProcessEnvironment.arguments(of: getpid()), Array(CommandLine.arguments.dropFirst()))
    }

    func testParseKeepsEqualsSignsInValues() {
        let buffer = procArgsBuffer(argv: ["x"], env: ["OPTS=a=b"])
        XCTAssertEqual(ProcessEnvironment.parse(procArgs: buffer)?["OPTS"], "a=b")
    }

    func testParseRejectsTruncatedBuffer() {
        XCTAssertNil(ProcessEnvironment.parse(procArgs: [1, 0]))
    }

    func testReadsEnvironmentOfOwnProcess() {
        let environment = ProcessEnvironment.environment(of: getpid())
        XCTAssertEqual(environment?["HOME"], ProcessInfo.processInfo.environment["HOME"])
    }

    // MARK: - Matching processes to instances

    private func makeInstance(dataPath: String) -> AppInstance {
        AppInstance(name: "Work Profile", application: makeTestApplication(), dataPath: URL(fileURLWithPath: dataPath))
    }

    func testMatchesProcessByAppAndHome() {
        let instance = makeInstance(dataPath: "/Volumes/External/Work")
        let process = RunningProcess(pid: 42, bundleURL: instance.targetAppPath, home: "/Volumes/External/Work")

        let matches = RunningInstanceMatcher.match(instances: [instance], processes: [process])

        XCTAssertEqual(matches, [instance.id: 42])
    }

    func testMatchIgnoresTrailingSlashInStoredDataPath() {
        // instances.json stores data paths as file URLs, sometimes with a trailing slash
        var instance = makeInstance(dataPath: "/Volumes/External/Work")
        instance.dataPath = URL(string: "file:///Volumes/External/Work/")!
        let process = RunningProcess(pid: 7, bundleURL: instance.targetAppPath, home: "/Volumes/External/Work")

        XCTAssertEqual(RunningInstanceMatcher.match(instances: [instance], processes: [process]), [instance.id: 7])
    }

    func testDoesNotMatchOriginalAppWithNormalHome() {
        let instance = makeInstance(dataPath: "/Volumes/External/Work")
        let process = RunningProcess(pid: 42, bundleURL: instance.targetAppPath, home: NSHomeDirectory())

        XCTAssertTrue(RunningInstanceMatcher.match(instances: [instance], processes: [process]).isEmpty)
    }

    func testDoesNotMatchOtherAppWithSameHome() {
        let instance = makeInstance(dataPath: "/Volumes/External/Work")
        let process = RunningProcess(pid: 42, bundleURL: URL(fileURLWithPath: "/Applications/Other.app"), home: "/Volumes/External/Work")

        XCTAssertTrue(RunningInstanceMatcher.match(instances: [instance], processes: [process]).isEmpty)
    }

    func testMatchesTwoInstancesOfSameApp() {
        let first = makeInstance(dataPath: "/Volumes/External/A")
        let second = makeInstance(dataPath: "/Volumes/External/B")
        let processes = [
            RunningProcess(pid: 1, bundleURL: first.targetAppPath, home: "/Volumes/External/B"),
            RunningProcess(pid: 2, bundleURL: first.targetAppPath, home: "/Volumes/External/A"),
        ]

        let matches = RunningInstanceMatcher.match(instances: [first, second], processes: processes)

        XCTAssertEqual(matches, [first.id: 2, second.id: 1])
    }
}
