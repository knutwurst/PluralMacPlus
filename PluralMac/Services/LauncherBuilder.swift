//
//  LauncherBuilder.swift
//  PluralMac
//
//  Created by Knutwurst on 13.10.26.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Builds a tiny .app that starts one instance without PluralMac Plus running. Inside is just a
/// shell script doing the same `open -n -a <target> --env ... --args ...` the app does. The target
/// app is never copied or modified.
struct LauncherBuilder {

    /// Info.plist key that marks a bundle as launcher of a specific instance
    static let instanceIDKey = "PluralMacPlusInstanceID"

    /// File name of the launcher script inside Contents/MacOS
    static let executableName = "launcher"

    enum LauncherError: LocalizedError, Equatable {
        case appAlreadyExists(URL)
        case notALauncher(URL)

        var errorDescription: String? {
            switch self {
            case .appAlreadyExists(let url):
                return "\"\(url.lastPathComponent)\" already exists in \(url.deletingLastPathComponent().path) and is not a launcher of this instance."
            case .notALauncher(let url):
                return "\"\(url.lastPathComponent)\" is not a launcher of this instance and was left untouched."
            }
        }
    }

    private let fileManager = FileManager.default

    // MARK: - Bundle

    func launcherURL(for instance: AppInstance, in folder: URL) -> URL {
        folder.appendingPathComponent("\(AppInstance.sanitizeFileName(instance.name)).app")
    }

    /// Replaces an older launcher of the same instance, refuses to touch any other app
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

    static func tinted(_ image: NSImage, hueDegrees: Double) -> NSImage {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return image
        }

        let filter = CIFilter.hueAdjust()
        filter.inputImage = CIImage(cgImage: cgImage)
        filter.angle = Float(hueDegrees * .pi / 180)

        guard let output = filter.outputImage,
              let result = CIContext().createCGImage(output, from: output.extent) else {
            return image
        }
        return NSImage(cgImage: result, size: image.size)
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

    func isUpToDate(_ bundle: URL, for instance: AppInstance) -> Bool {
        let executable = bundle.appendingPathComponent("Contents/MacOS/\(Self.executableName)")
        guard let current = try? String(contentsOf: executable, encoding: .utf8) else { return false }
        return current == script(for: instance)
    }

    /// Moves the launcher of `instanceID` to the Trash. A missing launcher is ignored; any other app is refused.
    static func remove(
        _ bundle: URL,
        for instanceID: UUID,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        guard FileManager.default.fileExists(atPath: bundle.path) else { return }
        guard isLauncher(at: bundle, for: instanceID) else {
            throw LauncherError.notALauncher(bundle)
        }
        try trash(bundle)
    }

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

    /// `cleanAppleDouble`: nil = decide from the data volume
    func script(for instance: AppInstance, cleanAppleDouble: Bool? = nil) -> String {
        let q = Self.shellQuote
        var lines = [
            "#!/bin/sh",
            "# PluralMac Plus launcher for \"\(instance.name)\" (\(instance.id.uuidString))",
            "# Generated by PluralMac Plus. Recreate it from the app after changing the instance.",
            "",
        ]

        lines += preparationLines(for: instance, cleanAppleDouble: cleanAppleDouble)

        var command = ["\(instance.privateCopy == nil ? "exec " : "")/usr/bin/open -n -a \(q(instance.launchAppPath.path))"]
        for (key, value) in instance.effectiveEnvironmentVariables.sorted(by: { $0.key < $1.key }) {
            command.append("--env \(q("\(key)=\(value)"))")
        }
        // A private copy or starter passes the arguments itself
        let arguments = instance.privateCopy == nil ? instance.effectiveCommandLineArguments : []
        if !arguments.isEmpty {
            command.append("--args " + arguments.map(q).joined(separator: " "))
        }
        lines.append(command.joined(separator: " \\\n    "))

        // LaunchServices grabs the copy once it runs; unregister it a bit later so bundle ID and
        // URL schemes belong to the original again
        if let copy = instance.privateCopy, !copy.isStarter {
            lines.append("( /bin/sleep 3; \(q(PrivateCopyBuilder.lsregisterPath)) -u \(q(copy.path.path)) ) >/dev/null 2>&1 &")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Main executable of a private copy, so Dock, Finder and Spotlight launches set up the instance
    /// too. bash, not sh: the device-ID override is an exported function, which sh can't do, and
    /// env(1) would lose DYLD_INSERT_LIBRARIES under SIP.
    func copyStartScript(for instance: AppInstance, executableName: String, cleanAppleDouble: Bool? = nil) -> String {
        // same LaunchServices unregister dance as in script(for:)
        let unregister = "( /bin/sleep 3; \(Self.shellQuote(PrivateCopyBuilder.lsregisterPath)) -u \"${0%/Contents/MacOS/*}\" ) >/dev/null 2>&1 &"
        return startScript(for: instance, title: "start script", extraLines: [unregister],
                           executable: "\"${0%/*}/\(executableName)\"", cleanAppleDouble: cleanAppleDouble)
    }

    /// Dock starter main executable: sets up the instance and execs the original binary. The process
    /// keeps the starter's Dock name and icon, the original stays untouched.
    func starterScript(for instance: AppInstance, binary: URL, cleanAppleDouble: Bool? = nil) -> String {
        startScript(for: instance, title: "Dock starter", extraLines: [],
                    executable: Self.shellQuote(binary.path), cleanAppleDouble: cleanAppleDouble)
    }

    private func startScript(for instance: AppInstance, title: String, extraLines: [String], executable: String, cleanAppleDouble: Bool?) -> String {
        let q = Self.shellQuote
        var lines = [
            "#!/bin/bash",
            "# PluralMac Plus \(title) for \"\(instance.name)\" (\(instance.id.uuidString))",
            "# Generated by PluralMac Plus; changes to the instance rewrite it.",
            "",
        ]
        lines += preparationLines(for: instance, cleanAppleDouble: cleanAppleDouble)
        if !extraLines.isEmpty {
            lines += extraLines + [""]
        }

        for (key, value) in instance.effectiveEnvironmentVariables.sorted(by: { $0.key < $1.key }) {
            if key == HardwareIdentity.environmentKey {
                lines.append("ioreg \(value)")
                lines.append("export -f ioreg")
            } else {
                lines.append("export \(key)=\(q(value))")
            }
        }
        lines.append("")

        let arguments = instance.effectiveCommandLineArguments.map(q).joined(separator: " ")
        lines.append("exec \(executable) \(arguments.isEmpty ? "" : arguments + " ")\"$@\"")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Volume check, data folder and FAT/exFAT cleanup shared by launcher and start script
    private func preparationLines(for instance: AppInstance, cleanAppleDouble: Bool?) -> [String] {
        let q = Self.shellQuote
        var lines: [String] = []
        // Don't start with an empty profile when the data lives on an unplugged drive
        if let volumeRoot = Self.volumeRoot(of: instance.isolationRoot) {
            let message = "The data of \(instance.name) is on \(volumeRoot.lastPathComponent), which is not connected."
            lines.append("if [ ! -d \(q(volumeRoot.path)) ]; then")
            lines.append("    /usr/bin/osascript -e \(q("display alert \"PluralMac Plus\" message \"\(message.replacingOccurrences(of: "\"", with: "'"))\" as critical"))")
            lines.append("    exit 1")
            lines.append("fi")
            lines.append("")
        }
        if instance.redirectsHome {
            lines.append("/bin/mkdir -p \(q(instance.isolationRoot.path))")
        }
        if let folder = instance.maintainedFolder, cleanAppleDouble ?? AppleDoubleCleaner.needsCleanup(at: folder) {
            // FAT/exFAT: companion "._*" files break apps that delete folders on startup
            lines.append("/usr/bin/find \(q(folder.path)) -name '._*' -type f -delete 2>/dev/null")
        }
        lines.append("")
        return lines
    }

    /// `/Volumes/<name>` if `url` is on an external volume
    private static func volumeRoot(of url: URL) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes").appendingPathComponent(components[2])
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
