//
//  BundleManager.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import AppKit
import OSLog
import CoreServices

/// Builds "trampoline" bundles: a tiny .app whose launcher script execs the original,
/// untouched app with the instance's environment. CEF/Electron apps refuse to start
/// when their own bundle has been modified, so I never copy or patch it.
actor BundleManager {

    static let shared = BundleManager()

    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "BundleManager")
    private let fileManager = FileManager.default

    let baseDirectory: URL

    var instancesDirectory: URL {
        baseDirectory.appendingPathComponent("Instances")
    }

    var dataDirectory: URL {
        baseDirectory.appendingPathComponent("Data")
    }

    var cacheDirectory: URL {
        baseDirectory.appendingPathComponent("Cache")
    }

    init(baseDirectory: URL = AppInstance.defaultBaseDirectory) {
        self.baseDirectory = baseDirectory
    }

    // MARK: - Directories

    func ensureDirectoriesExist() throws {
        let directories = [
            baseDirectory,
            instancesDirectory,
            dataDirectory,
            cacheDirectory,
            cacheDirectory.appendingPathComponent("Icons")
        ]

        for directory in directories {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                logger.info("Created directory: \(directory.path)")
            }
        }
    }

    // MARK: - Bundle Creation

    func createBundle(for instance: AppInstance) async throws {
        logger.info("Creating trampoline bundle for instance: \(instance.name)")

        try ensureDirectoriesExist()

        guard fileManager.fileExists(atPath: instance.targetAppPath.path) else {
            throw BundleError.targetAppNotFound(instance.targetAppPath)
        }

        if fileManager.fileExists(atPath: instance.shortcutPath.path) {
            try fileManager.removeItem(at: instance.shortcutPath)
            logger.debug("Removed existing bundle at: \(instance.shortcutPath.path)")
        }

        try createMinimalBundleStructure(for: instance)

        try createInfoPlist(for: instance)

        try createLauncherScript(for: instance)

        try await setupIcon(for: instance)

        try createDataDirectory(for: instance)

        // unsigned bundles get stopped by Gatekeeper
        try await signBundle(at: instance.shortcutPath)

        try registerWithLaunchServices(instance.shortcutPath)

        logger.info("Successfully created trampoline bundle: \(instance.shortcutPath.path)")
    }

    private func createMinimalBundleStructure(for instance: AppInstance) throws {
        let contentsPath = instance.shortcutPath.appendingPathComponent("Contents")
        let macOSPath = contentsPath.appendingPathComponent("MacOS")
        let resourcesPath = contentsPath.appendingPathComponent("Resources")

        try fileManager.createDirectory(at: macOSPath, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesPath, withIntermediateDirectories: true)

        logger.debug("Created minimal bundle structure at: \(instance.shortcutPath.path)")
    }

    private func createInfoPlist(for instance: AppInstance) throws {
        let plistPath = instance.shortcutPath
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")

        guard let originalBundle = Bundle(url: instance.targetAppPath),
              let originalExecName = originalBundle.executableURL?.lastPathComponent else {
            throw BundleError.invalidTargetBundle(instance.targetAppPath)
        }

        let originalBundleId = originalBundle.bundleIdentifier ?? "unknown"
        let originalVersion = originalBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

        let newBundleIdentifier = "com.knutwurst.pluralmacplus.\(instance.id.uuidString.lowercased())"
        let executableName = sanitizeExecutableName(instance.name)

        let plistDict: [String: Any] = [
            "CFBundleIdentifier": newBundleIdentifier,
            "CFBundleExecutable": executableName,
            "CFBundleName": instance.name,
            "CFBundleDisplayName": instance.name,
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleSignature": "????",
            "CFBundleShortVersionString": originalVersion,
            "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSMinimumSystemVersion": "11.0",
            "NSHighResolutionCapable": true,
            "LSUIElement": false,

            "PluralMacInstanceID": instance.id.uuidString,
            "PluralMacOriginalBundleID": originalBundleId,
            "PluralMacOriginalExecutable": originalExecName,
            "PluralMacTargetApp": instance.targetAppPath.path,
            "PluralMacCreatedAt": ISO8601DateFormatter().string(from: Date())
        ]

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plistDict,
            format: .xml,
            options: 0
        )

        try plistData.write(to: plistPath)

        logger.debug("Created Info.plist with Bundle ID: \(newBundleIdentifier)")
    }

    // MARK: - Launcher Script

    private func createLauncherScript(for instance: AppInstance) throws {
        guard let originalBundle = Bundle(url: instance.targetAppPath),
              let originalExecURL = originalBundle.executableURL else {
            throw BundleError.invalidTargetBundle(instance.targetAppPath)
        }

        let executableName = sanitizeExecutableName(instance.name)
        let launcherPath = instance.shortcutPath
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent(executableName)

        var script = """
        #!/bin/bash
        # PluralMac Trampoline Launcher
        # Instance: \(instance.name)
        # ID: \(instance.id.uuidString)
        # Generated: \(ISO8601DateFormatter().string(from: Date()))
        #
        # This launcher executes the ORIGINAL unmodified app binary
        # with custom environment variables for data isolation.

        """

        let envVars = instance.effectiveEnvironmentVariables
        if !envVars.isEmpty {
            script += "# Environment Variables for Data Isolation\n"
            for (key, value) in envVars {
                let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
                script += "export \(key)=\"\(escapedValue)\"\n"
            }
            script += "\n"
        }

        let originalExecPath = originalExecURL.path
        script += "# Execute the ORIGINAL app binary (unmodified, preserving code signature)\n"
        script += "exec \"\(originalExecPath)\""

        let args = instance.effectiveCommandLineArguments
        for arg in args {
            let escapedArg = arg.replacingOccurrences(of: "\"", with: "\\\"")
            script += " \"\(escapedArg)\""
        }

        script += " \"$@\"\n"

        try script.write(to: launcherPath, atomically: true, encoding: .utf8)

        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcherPath.path
        )

        logger.debug("Created launcher script at: \(launcherPath.path)")
    }

    // MARK: - Code Signing

    private func signBundle(at bundlePath: URL) async throws {
        logger.debug("Signing bundle at: \(bundlePath.path)")

        let codesignProcess = Process()
        codesignProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesignProcess.arguments = [
            "--sign", "-",           // ad-hoc
            "--force",
            bundlePath.path
        ]

        let pipe = Pipe()
        codesignProcess.standardError = pipe

        try codesignProcess.run()
        codesignProcess.waitUntilExit()

        if codesignProcess.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            logger.warning("Codesign warning: \(errorMessage)")
            // not fatal, the bundle may still launch
        }

        logger.debug("Successfully signed bundle")
    }

    // MARK: - Icon

    private func setupIcon(for instance: AppInstance) async throws {
        let resourcesPath = instance.shortcutPath
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")

        let iconDestination = resourcesPath.appendingPathComponent("AppIcon.icns")

        if let customIconPath = instance.customIconPath,
           fileManager.fileExists(atPath: customIconPath.path) {
            let pathExtension = customIconPath.pathExtension.lowercased()

            if pathExtension == "icns" {
                try fileManager.copyItem(at: customIconPath, to: iconDestination)
            } else {
                let customImage = try await IconExtractor.shared.loadCustomIcon(from: customIconPath)
                try await IconExtractor.shared.saveAsICNS(image: customImage, to: iconDestination)
            }
            logger.debug("Copied custom icon to bundle")
        } else {
            try await extractAndCopyIcon(
                from: instance.targetAppPath,
                to: iconDestination
            )
        }
    }

    private func extractAndCopyIcon(from appPath: URL, to destination: URL) async throws {
        do {
            let icon = try await IconExtractor.shared.extractIcon(from: appPath, size: 512)
            try await IconExtractor.shared.saveAsICNS(image: icon, to: destination)
            logger.debug("Extracted and saved icon using IconExtractor")
        } catch {
            try await fallbackIconCopy(from: appPath, to: destination)
        }
    }

    private func fallbackIconCopy(from appPath: URL, to destination: URL) async throws {
        guard let bundle = Bundle(url: appPath) else {
            throw BundleError.invalidTargetBundle(appPath)
        }

        if let iconFileName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            var iconName = iconFileName
            if !iconName.hasSuffix(".icns") {
                iconName += ".icns"
            }

            let potentialPath = appPath
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent(iconName)

            if fileManager.fileExists(atPath: potentialPath.path) {
                try fileManager.copyItem(at: potentialPath, to: destination)
                logger.debug("Copied icon directly from bundle")
                return
            }
        }

        // last resort: whatever NSWorkspace hands out
        try await MainActor.run {
            let workspace = NSWorkspace.shared
            let icon = workspace.icon(forFile: appPath.path)

            guard let tiffData = icon.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                throw BundleError.iconExtractionFailed(appPath)
            }

            // crude: PNG data under the .icns name
            try pngData.write(to: destination)

            logger.debug("Extracted icon using NSWorkspace fallback")
        }
    }

    // MARK: - Data Directory

    private func createDataDirectory(for instance: AppInstance) throws {
        let dataPath = instance.dataPath

        if !fileManager.fileExists(atPath: dataPath.path) {
            try fileManager.createDirectory(
                at: dataPath,
                withIntermediateDirectories: true
            )
        }

        // symlinks only make sense when HOME points into the data dir
        guard instance.effectiveIsolationMethod == .homeRedirection else {
            return
        }

        // Link the user folders and the keychain back to the real home. Without the
        // keychain link, apps with a redirected HOME can't find their keychain items.
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let symlinks: [(String, String)] = [
            ("Desktop", "Desktop"),
            ("Documents", "Documents"),
            ("Downloads", "Downloads"),
            ("Movies", "Movies"),
            ("Music", "Music"),
            ("Pictures", "Pictures"),
            ("Public", "Public"),

            ("Library/Keychains", "Library/Keychains"),
            ("Library/Preferences/com.apple.security.plist", "Library/Preferences/com.apple.security.plist"),
        ]

        for (relativePath, targetRelativePath) in symlinks {
            let linkPath = dataPath.appendingPathComponent(relativePath)
            let targetPath = homeDirectory.appendingPathComponent(targetRelativePath)

            let parentDir = linkPath.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            if fileManager.fileExists(atPath: targetPath.path) &&
               !fileManager.fileExists(atPath: linkPath.path) {
                try fileManager.createSymbolicLink(at: linkPath, withDestinationURL: targetPath)
                logger.debug("Created symlink: \(relativePath) -> \(targetPath.path)")
            }
        }

        let libraryPaths = [
            "Library",
            "Library/Application Support",
            "Library/Caches",
            "Library/Preferences",
            "Library/Logs"
        ]

        for path in libraryPaths {
            let fullPath = dataPath.appendingPathComponent(path)
            if !fileManager.fileExists(atPath: fullPath.path) {
                try fileManager.createDirectory(at: fullPath, withIntermediateDirectories: true)
            }
        }

        logger.debug("Created data directory with symlinks at: \(dataPath.path)")
    }

    // MARK: - Launch Services

    private func registerWithLaunchServices(_ bundlePath: URL) throws {
        let status = LSRegisterURL(bundlePath as CFURL, true)

        if status != noErr {
            logger.warning("LSRegisterURL returned status: \(status)")
            // not critical, so no throw
        } else {
            logger.debug("Registered bundle with Launch Services")
        }
    }

    // MARK: - Deletion / Update

    func deleteBundle(for instance: AppInstance, deleteData: Bool = false) throws {
        logger.info("Deleting bundle for instance: \(instance.name)")

        if fileManager.fileExists(atPath: instance.shortcutPath.path) {
            try fileManager.removeItem(at: instance.shortcutPath)
            logger.debug("Deleted bundle at: \(instance.shortcutPath.path)")
        }

        // careful: this wipes the instance's user data for good
        if deleteData && fileManager.fileExists(atPath: instance.dataPath.path) {
            try fileManager.removeItem(at: instance.dataPath)
            logger.debug("Deleted data at: \(instance.dataPath.path)")
        }

        logger.info("Successfully deleted bundle for: \(instance.name)")
    }

    func updateBundle(for instance: AppInstance) async throws {
        logger.info("Updating bundle for instance: \(instance.name)")

        try await createBundle(for: instance)

        logger.info("Successfully updated bundle: \(instance.name)")
    }

    // MARK: - Helpers

    private func sanitizeExecutableName(_ name: String) -> String {
        let invalidCharacters = CharacterSet.alphanumerics.inverted
        let sanitized = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)

        return sanitized.isEmpty ? "Launcher" : sanitized
    }

    func bundleExists(for instance: AppInstance) -> Bool {
        fileManager.fileExists(atPath: instance.shortcutPath.path)
    }

    func dataDirectorySize(for instance: AppInstance) throws -> Int64 {
        guard fileManager.fileExists(atPath: instance.dataPath.path) else {
            return 0
        }

        var totalSize: Int64 = 0

        if let enumerator = fileManager.enumerator(
            at: instance.dataPath,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if resourceValues.isDirectory == false {
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                }
            }
        }

        return totalSize
    }
}

// MARK: - Errors

enum BundleError: LocalizedError {
    case targetAppNotFound(URL)
    case invalidTargetBundle(URL)
    case invalidBundleStructure(String)
    case iconExtractionFailed(URL)
    case bundleCreationFailed(String)
    case launcherCreationFailed(String)
    case permissionDenied(URL)

    var errorDescription: String? {
        switch self {
        case .targetAppNotFound(let url):
            return "Target application not found at: \(url.path)"
        case .invalidTargetBundle(let url):
            return "Invalid application bundle at: \(url.path)"
        case .invalidBundleStructure(let message):
            return "Invalid bundle structure: \(message)"
        case .iconExtractionFailed(let url):
            return "Failed to extract icon from: \(url.path)"
        case .bundleCreationFailed(let message):
            return "Failed to create bundle: \(message)"
        case .launcherCreationFailed(let message):
            return "Failed to create launcher: \(message)"
        case .permissionDenied(let url):
            return "Permission denied for: \(url.path)"
        }
    }
}
