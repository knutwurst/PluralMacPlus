//
//  LauncherBuilder.swift
//  PluralMac
//
//  Created by Knutwurst on 13.10.26.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Builds a tiny .app bundle that starts one instance directly, without PluralMac Plus running.
/// The bundle only contains a shell script that calls `open -n -a <target> --env ... --args ...`,
/// the same launch PluralMac Plus performs itself. The target app is never copied or modified.
struct LauncherBuilder {

    /// Info.plist key that marks a bundle as launcher of a specific instance
    static let instanceIDKey = "PluralMacPlusInstanceID"

    /// File name of the launcher script inside Contents/MacOS
    static let executableName = "launcher"

    enum LauncherError: LocalizedError, Equatable {
        case appAlreadyExists(URL)

        var errorDescription: String? {
            switch self {
            case .appAlreadyExists(let url):
                return "\"\(url.lastPathComponent)\" already exists in \(url.deletingLastPathComponent().path) and is not a launcher of this instance."
            }
        }
    }

    private let fileManager = FileManager.default

    // MARK: - Bundle

    /// Location of the launcher for `instance` inside `folder`
    func launcherURL(for instance: AppInstance, in folder: URL) -> URL {
        folder.appendingPathComponent("\(AppInstance.sanitizeFileName(instance.name)).app")
    }

    /// Writes the launcher bundle into `folder` and returns its location.
    /// An existing launcher of the same instance is replaced; any other existing app is left alone.
    @discardableResult
    func build(for instance: AppInstance, in folder: URL) throws -> URL {
        let bundle = launcherURL(for: instance, in: folder)

        if fileManager.fileExists(atPath: bundle.path) {
            guard Self.isLauncher(at: bundle, for: instance.id) else {
                throw LauncherError.appAlreadyExists(bundle)
            }
            try fileManager.removeItem(at: bundle)
        }

        let contents = bundle.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

        let plist = try PropertyListSerialization.data(fromPropertyList: infoPlist(for: instance), format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))

        let executable = macOS.appendingPathComponent(Self.executableName)
        try script(for: instance).write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        return bundle
    }

    /// Writes `image` as Contents/Resources/AppIcon.icns. A missing icon is not fatal.
    func writeIcon(_ image: NSImage, into bundle: URL) {
        let url = bundle.appendingPathComponent("Contents/Resources/AppIcon.icns")
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, sizes.count, nil) else {
            return
        }
        for size in sizes {
            var rect = NSRect(x: 0, y: 0, width: size, height: size)
            if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                CGImageDestinationAddImage(destination, cgImage, nil)
            }
        }
        CGImageDestinationFinalize(destination)
    }

    /// Ad-hoc signs the bundle. Failure is not fatal: a locally created launcher runs unsigned.
    func sign(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--sign", "-", "--force", bundle.path]
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    /// Whether `bundle` is a launcher created for the instance with `instanceID`
    static func isLauncher(at bundle: URL, for instanceID: UUID) -> Bool {
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        return plist[instanceIDKey] as? String == instanceID.uuidString
    }

    private func infoPlist(for instance: AppInstance) -> [String: Any] {
        [
            "CFBundleIdentifier": "com.knutwurst.pluralmacplus.launcher.\(instance.id.uuidString.lowercased())",
            "CFBundleExecutable": Self.executableName,
            "CFBundleName": instance.name,
            "CFBundleDisplayName": instance.name,
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSMinimumSystemVersion": "14.0",
            // The launcher exits right after starting the instance; keep it out of the Dock
            "LSUIElement": true,
            Self.instanceIDKey: instance.id.uuidString,
        ]
    }

    // MARK: - Script

    /// Shell script that starts the instance
    func script(for instance: AppInstance) -> String {
        let q = Self.shellQuote
        var lines = [
            "#!/bin/sh",
            "# PluralMac Plus launcher for \"\(instance.name)\" (\(instance.id.uuidString))",
            "# Generated by PluralMac Plus. Recreate it from the app after changing the instance.",
            "",
        ]

        // Don't start with an empty profile when the data lives on an unplugged drive
        if let volumeRoot = Self.volumeRoot(of: instance.dataPath) {
            let message = "The data of \(instance.name) is on \(volumeRoot.lastPathComponent), which is not connected."
            lines.append("if [ ! -d \(q(volumeRoot.path)) ]; then")
            lines.append("    /usr/bin/osascript -e \(q("display alert \"PluralMac Plus\" message \"\(message.replacingOccurrences(of: "\"", with: "'"))\" as critical"))")
            lines.append("    exit 1")
            lines.append("fi")
            lines.append("")
        }

        lines.append("/bin/mkdir -p \(q(instance.dataPath.path))")
        lines.append("")

        var command = ["exec /usr/bin/open -n -a \(q(instance.targetAppPath.path))"]
        for (key, value) in instance.effectiveEnvironmentVariables.sorted(by: { $0.key < $1.key }) {
            command.append("--env \(q("\(key)=\(value)"))")
        }
        let arguments = instance.effectiveCommandLineArguments
        if !arguments.isEmpty {
            command.append("--args " + arguments.map(q).joined(separator: " "))
        }
        lines.append(command.joined(separator: " \\\n    "))

        return lines.joined(separator: "\n") + "\n"
    }

    /// `/Volumes/<name>` if `url` is on an external volume
    private static func volumeRoot(of url: URL) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes").appendingPathComponent(components[2])
    }

    /// Single-quotes a string for /bin/sh
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
