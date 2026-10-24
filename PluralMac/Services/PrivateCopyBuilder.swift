//
//  PrivateCopyBuilder.swift
//  PluralMac
//
//  Created by Knutwurst on 14.10.26.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A private copy of the target app that an instance runs instead of the original
struct PrivateAppCopy: Codable, Hashable, Sendable {
    var path: URL

    /// Version of the original the copy was made from ("short (build)")
    var originalVersion: String

    var createdAt: Date

    /// Icon hue the copy was built with (nil = original colors)
    var iconHue: Double?

    enum Kind: String, Codable, Sendable {
        /// Re-signed clone of the whole app
        case clone
        /// Small bundle with its own name and icon that execs the original binary
        case starter
    }

    /// nil = clone (copies made before starters existed)
    var kind: Kind?

    var isStarter: Bool { kind == .starter }
}

/// Builds private app copies: an APFS clone of the original, renamed to the instance, with its own
/// icon, re-signed ad hoc without Hardened Runtime so the preferences shim can be injected.
nonisolated struct PrivateCopyBuilder {

    enum CopyError: LocalizedError {
        case copyFailed(String)
        case signingFailed(String)

        var errorDescription: String? {
            switch self {
            case .copyFailed(let reason): return "Copying the app failed: \(reason)"
            case .signingFailed(let reason): return "Signing the private copy failed: \(reason)"
            }
        }
    }

    /// Icon file the copy uses (without extension, as in CFBundleIconFile)
    static let iconFileName = "PluralMacPlusIcon"

    /// Main executable of the copy: sets up the instance, then execs the app's real binary
    static let startScriptName = "PluralMacPlusStart"

    /// Info.plist key that remembers the real binary's name
    static let originalExecutableKey = "PluralMacPlusOriginalExecutable"

    /// Entitlements that need an Apple-issued provisioning profile; an ad-hoc signed app carrying
    /// them would be killed at launch
    static let restrictedEntitlementPrefixes = [
        "com.apple.application-identifier",
        "com.apple.developer.",
        "keychain-access-groups",
        "aps-environment",
        "com.apple.security.application-groups",
    ]

    static var defaultClonesDirectory: URL {
        AppInstance.defaultBaseDirectory.appendingPathComponent("Clones")
    }

    let clonesDirectory: URL

    /// Old copies go to the Trash, never straight into the void
    var removeItem: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    init(clonesDirectory: URL = PrivateCopyBuilder.defaultClonesDirectory) {
        self.clonesDirectory = clonesDirectory
    }

    // MARK: - Building

    func build(instanceID: UUID, name: String, original: URL, iconPNG: Data?, startScript: String, starter: Bool = false) throws -> PrivateAppCopy {
        let folder = clonesDirectory.appendingPathComponent(instanceID.uuidString)
        if FileManager.default.fileExists(atPath: folder.path) {
            try removeItem(folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let copy = folder.appendingPathComponent("\(AppInstance.sanitizeFileName(name)).app")
        if starter {
            try writeStarter(at: copy, instanceID: instanceID, name: name, iconPNG: iconPNG, startScript: startScript)
            return PrivateAppCopy(path: copy, originalVersion: Self.versionString(of: original), createdAt: Date(), kind: .starter)
        }
        try cloneBundle(from: original, to: copy)
        try? FileManager.default.removeItem(at: copy.appendingPathComponent("Contents/embedded.provisionprofile"))

        try applyIdentity(to: copy, name: name, iconPNG: iconPNG, startScript: startScript)

        // order matters: nested code keeps its entitlements, the real binary gets the filtered ones
        // without Hardened Runtime, and the bundle is sealed last with the start script as main executable
        try codesign(["--force", "--deep", "--sign", "-", "--preserve-metadata=entitlements", copy.path])
        try signRealBinary(of: copy, original: original)
        try codesign(["--force", "--sign", "-", copy.path])
        try codesign(["--verify", "--deep", "--strict", copy.path])
        Self.markChanged(copy)

        return PrivateAppCopy(path: copy, originalVersion: Self.versionString(of: original), createdAt: Date())
    }

    /// Applies a new name and icon to an existing copy (no new clone)
    func updateIdentity(of current: PrivateAppCopy, instanceID: UUID, name: String, original: URL, iconPNG: Data?, startScript: String) throws -> PrivateAppCopy {
        var updated = current
        let renamed = current.path.deletingLastPathComponent()
            .appendingPathComponent("\(AppInstance.sanitizeFileName(name)).app")
        if renamed.standardizedFileURL != current.path.standardizedFileURL {
            try FileManager.default.moveItem(at: current.path, to: renamed)
            updated.path = renamed
        }

        if current.isStarter {
            try writeStarter(at: updated.path, instanceID: instanceID, name: name, iconPNG: iconPNG, startScript: startScript)
            return updated
        }

        try applyIdentity(to: updated.path, name: name, iconPNG: iconPNG, startScript: startScript)
        // copies from older versions signed the real binary as main executable, bound to the old
        // Info.plist. Sign it on its own before sealing the bundle again
        try signRealBinary(of: updated.path, original: original)
        try codesign(["--force", "--sign", "-", updated.path.path])
        try codesign(["--verify", "--deep", "--strict", updated.path.path])
        Self.markChanged(updated.path)
        return updated
    }

    // MARK: - Steps

    /// Dock starter: own Info.plist, name and bundle ID, start script as executable, icon.
    /// Nothing of the original gets copied.
    private func writeStarter(at bundle: URL, instanceID: UUID, name: String, iconPNG: Data?, startScript: String) throws {
        let contents = bundle.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleIdentifier": "com.knutwurst.pluralmacplus.starter.\(instanceID.uuidString.lowercased())",
            "CFBundleExecutable": Self.startScriptName,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSMinimumSystemVersion": "14.0",
            // Unlike a launcher, the starter becomes the running app and has to show in the Dock
            "LSUIElement": false,
            "NSHighResolutionCapable": true,
            LauncherBuilder.instanceIDKey: instanceID.uuidString,
        ]
        let iconURL = resources.appendingPathComponent("\(Self.iconFileName).icns")
        if let iconPNG, Self.writeIcon(iconPNG, to: iconURL) {
            info["CFBundleIconFile"] = Self.iconFileName
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let scriptURL = macOS.appendingPathComponent(Self.startScriptName)
        try startScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        try codesign(["--force", "--sign", "-", bundle.path])
        try codesign(["--verify", "--deep", "--strict", bundle.path])
        Self.markChanged(bundle)
    }

    private func cloneBundle(from source: URL, to destination: URL) throws {
        // COPYFILE_CLONE makes an APFS clone (near-zero disk use) and falls back to a copy
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw CopyError.copyFailed(String(cString: strerror(errno)))
        }
    }

    private func applyIdentity(to copy: URL, name: String, iconPNG: Data?, startScript: String) throws {
        let contents = copy.appendingPathComponent("Contents")
        let infoURL = contents.appendingPathComponent("Info.plist")
        guard let info = NSMutableDictionary(contentsOf: infoURL) else {
            throw CopyError.copyFailed("Info.plist is unreadable")
        }

        info["CFBundleName"] = name
        info["CFBundleDisplayName"] = name
        // A bundled Sparkle updater must not patch the copy
        info["SUEnableAutomaticChecks"] = false
        info["SUAutomaticallyUpdate"] = false

        // The start script becomes the main executable; the real binary keeps its name
        let executable = info[Self.originalExecutableKey] as? String ?? info["CFBundleExecutable"] as? String ?? ""
        info[Self.originalExecutableKey] = executable
        info["CFBundleExecutable"] = Self.startScriptName
        let scriptURL = contents.appendingPathComponent("MacOS/\(Self.startScriptName)")
        try startScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        if let iconPNG, Self.writeIcon(iconPNG, to: contents.appendingPathComponent("Resources/\(Self.iconFileName).icns")) {
            info.removeObject(forKey: "CFBundleIconName")
            info["CFBundleIconFile"] = Self.iconFileName
        }

        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        try removeLocalizedNames(in: contents.appendingPathComponent("Resources"))
    }

    /// Localized InfoPlist.strings would override the instance name
    private func removeLocalizedNames(in resources: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in enumerator where file.lastPathComponent == "InfoPlist.strings" {
            guard let strings = NSDictionary(contentsOf: file) as? [String: String] else { continue }
            let remaining = strings.filter { $0.key != "CFBundleName" && $0.key != "CFBundleDisplayName" }
            guard remaining.count != strings.count else { continue }

            let text = remaining.sorted { $0.key < $1.key }
                .map { "\"\(Self.escape($0.key))\" = \"\(Self.escape($0.value))\";" }
                .joined(separator: "\n") + "\n"
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func signRealBinary(of copy: URL, original: URL) throws {
        let info = NSDictionary(contentsOf: copy.appendingPathComponent("Contents/Info.plist"))
        let executable = info?[Self.originalExecutableKey] as? String ?? ""
        let binary = copy.appendingPathComponent("Contents/MacOS/\(executable)")
        let entitlements = Self.filteredEntitlements(PreferencesIsolation.entitlements(appAt: original))
        var arguments = ["--force", "--sign", "-"]
        if !entitlements.isEmpty {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("pmp-entitlements-\(UUID().uuidString).plist")
            try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            arguments += ["--entitlements", file.path]
            try codesign(arguments + [binary.path])
        } else {
            try codesign(arguments + [binary.path])
        }
    }

    private func codesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CopyError.signingFailed(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Helpers

    static func filteredEntitlements(_ entitlements: [String: Any]) -> [String: Any] {
        entitlements.filter { key, _ in
            !restrictedEntitlementPrefixes.contains { key.hasPrefix($0) }
        }
    }

    /// "4.0.6 (1)" from CFBundleShortVersionString and CFBundleVersion
    static func versionString(of app: URL) -> String {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// After a launch LaunchServices hands the app's bundle ID and URL schemes to the copy.
    /// Unregistering gives them back to the original.
    static func unregisterFromLaunchServices(_ copy: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = ["-u", copy.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    /// macOS caches name and icon like a squirrel caches nuts and only rereads them when the bundle
    /// folder's mtime changes. The clone keeps the original's date, so bump it, let LaunchServices
    /// reread once and unregister again.
    static func markChanged(_ copy: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: copy.path)
        runLsregister(["-f", copy.path])
        unregisterFromLaunchServices(copy)
    }

    private static func runLsregister(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    static let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    private static func writeIcon(_ png: Data, to url: URL) -> Bool {
        // ICNS only accepts its standard sizes, so scale the source into each of them
        let sizes = [16, 32, 64, 128, 256, 512]
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, sizes.count, nil) else {
            return false
        }
        for size in sizes {
            guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            if let scaled = context.makeImage() {
                CGImageDestinationAddImage(destination, scaled, nil)
            }
        }
        return CGImageDestinationFinalize(destination)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - Instance convenience

extension PrivateCopyBuilder {

    func build(for instance: AppInstance, icon: NSImage?) throws -> PrivateAppCopy {
        var fresh = instance
        fresh.privateCopy = nil
        return try build(instanceID: instance.id, name: instance.name, original: instance.targetAppPath,
                         iconPNG: icon.flatMap(Self.pngData), startScript: Self.startScript(for: fresh),
                         starter: Self.usesStarter(fresh))
    }

    func updateIdentity(of instance: AppInstance, icon: NSImage?) throws -> PrivateAppCopy? {
        guard let current = instance.privateCopy else { return nil }
        return try updateIdentity(of: current, instanceID: instance.id, name: instance.name, original: instance.targetAppPath,
                                  iconPNG: icon.flatMap(Self.pngData), startScript: Self.startScript(for: instance))
    }

    /// Starter instead of a re-signed clone? Apps isolated by argument get a starter, a clone would
    /// only risk losing access to their keychain items.
    static func usesStarter(_ instance: AppInstance) -> Bool {
        instance.privateCopy.map(\.isStarter) ?? !instance.canUsePrivateCopy
    }

    /// Start script for the instance's copy or starter, calling the original app's binary
    static func startScript(for instance: AppInstance) -> String {
        let info = NSDictionary(contentsOf: instance.targetAppPath.appendingPathComponent("Contents/Info.plist"))
        let executable = info?["CFBundleExecutable"] as? String ?? ""
        if usesStarter(instance) {
            let binary = instance.targetAppPath.appendingPathComponent("Contents/MacOS/\(executable)")
            return LauncherBuilder().starterScript(for: instance, binary: binary)
        }
        return LauncherBuilder().copyStartScript(for: instance, executableName: executable)
    }

    /// Whether name, icon color or start script of the copy no longer match the instance
    static func needsRefresh(_ instance: AppInstance) -> Bool {
        guard let copy = instance.privateCopy else { return false }
        let name = NSDictionary(contentsOf: copy.path.appendingPathComponent("Contents/Info.plist"))?["CFBundleName"] as? String
        return name != instance.name
            || copy.iconHue != instance.launcherIconHue
            || isStartScriptOutdated(instance)
    }

    /// Whether the copy's code signature verifies (a broken one keeps macOS from starting it)
    static func isSignatureValid(_ copy: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", copy.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func isStartScriptOutdated(_ instance: AppInstance) -> Bool {
        guard let copy = instance.privateCopy else { return false }
        let script = try? String(contentsOf: copy.path.appendingPathComponent("Contents/MacOS/\(startScriptName)"), encoding: .utf8)
        return script != startScript(for: instance)
    }

    /// Whether the original app changed since the copy was made (a starter always runs the current original)
    static func isOutdated(_ instance: AppInstance) -> Bool {
        guard let copy = instance.privateCopy, !copy.isStarter else { return false }
        return versionString(of: instance.targetAppPath) != copy.originalVersion
    }

    /// 1024 px PNG of an icon, so it can cross into background work
    static func pngData(_ image: NSImage) -> Data? {
        var rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
