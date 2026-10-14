//
//  RunningInstanceDiscovery.swift
//  PluralMac
//
//  Created by Knutwurst on 13.10.26.
//

import AppKit
import Darwin

/// Reads the environment of another process of the same user.
nonisolated enum ProcessEnvironment {

    /// Environment of `pid`, or nil if it can't be read
    static func environment(of pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(procArgs: Array(buffer.prefix(size)))
    }

    /// Parses a KERN_PROCARGS2 buffer: argc, executable path, padding, argv strings, environment strings
    static func parse(procArgs bytes: [UInt8]) -> [String: String]? {
        let argcSize = MemoryLayout<Int32>.size
        guard bytes.count > argcSize else { return nil }
        let argc = bytes.prefix(argcSize).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }

        var index = argcSize
        // Executable path, then NUL padding
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return value
        }

        for _ in 0..<max(argc, 0) {
            guard nextString() != nil else { return nil }
        }

        var environment: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return environment
    }
}

/// A running app process as seen by instance discovery
nonisolated struct RunningProcess: Equatable {
    let pid: pid_t
    let bundleURL: URL
    /// HOME of the process (instances run with HOME = their data folder)
    let home: String?
}

/// Maps running processes to the instances they belong to.
enum RunningInstanceMatcher {

    /// Instance ID → PID for every process that runs an instance
    static func match(instances: [AppInstance], processes: [RunningProcess]) -> [UUID: pid_t] {
        var matches: [UUID: pid_t] = [:]
        for instance in instances {
            let appPath = instance.launchAppPath.standardizedFileURL.path
            let dataPath = instance.dataPath.standardizedFileURL.path

            let process = processes.first { process in
                guard let home = process.home else { return false }
                return process.bundleURL.standardizedFileURL.path == appPath
                    && URL(fileURLWithPath: home).standardizedFileURL.path == dataPath
            }
            if let process {
                matches[instance.id] = process.pid
            }
        }
        return matches
    }

    /// Running processes of the instances' target apps, including their HOME
    static func runningProcesses(for instances: [AppInstance]) -> [RunningProcess] {
        let targetPaths = Set(instances.map { $0.launchAppPath.standardizedFileURL.path })

        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleURL = app.bundleURL,
                  targetPaths.contains(bundleURL.standardizedFileURL.path) else {
                return nil
            }
            let home = ProcessEnvironment.environment(of: app.processIdentifier)?["HOME"]
            return RunningProcess(pid: app.processIdentifier, bundleURL: bundleURL, home: home)
        }
    }
}
