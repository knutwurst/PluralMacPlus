//
//  HomeContainerBuilder.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import OSLog

/// Builds the fake HOME an instance runs in: its own Library, plus symlinks back to the
/// real home for user folders, keychains and the like.
struct HomeContainerBuilder: Sendable {

    private static let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "HomeContainerBuilder")
    private static let fileManager = FileManager.default

    // MARK: - Layout

    /// Symlinked to the real HOME, so every instance sees the same ones.
    static let sharedDirectories: [String] = [
        "Desktop",
        "Documents",
        "Downloads",
        "Movies",
        "Music",
        "Pictures",
        "Public",

        "Library/Keychains",                    // keychain lookups fail without this
        "Library/Group Containers",
        "Library/Fonts",
    ]

    static let sharedFiles: [String] = [
        "Library/Preferences/com.apple.security.plist",
        "Library/Preferences/.GlobalPreferences.plist",
    ]

    /// Real directories, one set per instance.
    static let isolatedDirectories: [String] = [
        "Library",
        "Library/Application Support",
        "Library/Caches",
        "Library/Containers",
        "Library/Cookies",
        "Library/HTTPStorages",
        "Library/Logs",
        "Library/Preferences",
        "Library/Saved Application State",
        "Library/WebKit",
    ]

    // MARK: - Build

    static func buildContainer(
        at containerPath: URL,
        for appType: AppType
    ) throws {
        logger.info("Building HOME container at: \(containerPath.path)")

        let realHome = fileManager.homeDirectoryForCurrentUser

        if !fileManager.fileExists(atPath: containerPath.path) {
            try fileManager.createDirectory(
                at: containerPath,
                withIntermediateDirectories: true
            )
        }

        for relativePath in isolatedDirectories {
            let fullPath = containerPath.appendingPathComponent(relativePath)
            if !fileManager.fileExists(atPath: fullPath.path) {
                try fileManager.createDirectory(
                    at: fullPath,
                    withIntermediateDirectories: true
                )
            }
        }

        for relativePath in sharedDirectories {
            try createSymlinkIfNeeded(
                from: containerPath.appendingPathComponent(relativePath),
                to: realHome.appendingPathComponent(relativePath)
            )
        }

        for relativePath in sharedFiles {
            try createSymlinkIfNeeded(
                from: containerPath.appendingPathComponent(relativePath),
                to: realHome.appendingPathComponent(relativePath)
            )
        }

        try applyAppTypeSpecificSetup(at: containerPath, for: appType)

        logger.info("Successfully built HOME container")
    }

    /// No-op if the link is already there or the target is missing.
    private static func createSymlinkIfNeeded(from linkPath: URL, to targetPath: URL) throws {
        if fileManager.fileExists(atPath: linkPath.path) {
            return
        }

        guard fileManager.fileExists(atPath: targetPath.path) else {
            logger.debug("Skipping symlink (target doesn't exist): \(targetPath.path)")
            return
        }

        let parentDir = linkPath.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true
            )
        }

        try fileManager.createSymbolicLink(
            at: linkPath,
            withDestinationURL: targetPath
        )

        logger.debug("Created symlink: \(linkPath.lastPathComponent)")
    }

    private static func applyAppTypeSpecificSetup(at containerPath: URL, for appType: AppType) throws {
        switch appType {
        case .chromium:
            try createDirectoryIfNeeded(
                containerPath.appendingPathComponent("Library/Application Support/Google")
            )

        case .firefox:
            try createDirectoryIfNeeded(
                containerPath.appendingPathComponent("Library/Application Support/Mozilla")
            )
            try createDirectoryIfNeeded(
                containerPath.appendingPathComponent("Library/Caches/Mozilla")
            )

        case .electron, .toDesktop:
            // isolatedDirectories already has what they need
            break

        case .generic:
            break

        case .sandboxed, .system:
            logger.warning("Attempted to create container for unsupported app type: \(appType.rawValue)")
        }
    }

    private static func createDirectoryIfNeeded(_ path: URL) throws {
        if !fileManager.fileExists(atPath: path.path) {
            try fileManager.createDirectory(
                at: path,
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Cleanup

    static func removeContainer(at containerPath: URL, preserveSharedLinks: Bool = true) throws {
        logger.info("Removing HOME container at: \(containerPath.path)")

        guard fileManager.fileExists(atPath: containerPath.path) else {
            logger.debug("Container doesn't exist, nothing to remove")
            return
        }

        // Both branches do the same thing for now. removeItem drops the symlinks
        // themselves and leaves their targets in the real HOME alone.
        if preserveSharedLinks {
            try fileManager.removeItem(at: containerPath)
        } else {
            try fileManager.removeItem(at: containerPath)
        }

        logger.info("Successfully removed HOME container")
    }

    /// Size of the instance's own data; symlinked folders don't count.
    static func isolatedDataSize(at containerPath: URL) throws -> Int64 {
        guard fileManager.fileExists(atPath: containerPath.path) else {
            return 0
        }

        var totalSize: Int64 = 0

        guard let enumerator = fileManager.enumerator(
            at: containerPath,
            includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey]
            )

            if resourceValues.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            if resourceValues.isDirectory == false {
                totalSize += Int64(resourceValues.fileSize ?? 0)
            }
        }

        return totalSize
    }

    // MARK: - Validation

    static func validateContainer(at containerPath: URL) -> ContainerValidationResult {
        var missingDirectories: [String] = []
        var brokenSymlinks: [String] = []

        for relativePath in isolatedDirectories {
            let fullPath = containerPath.appendingPathComponent(relativePath)
            if !fileManager.fileExists(atPath: fullPath.path) {
                missingDirectories.append(relativePath)
            }
        }

        for relativePath in sharedDirectories {
            let linkPath = containerPath.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: linkPath.path) {
                do {
                    let destination = try fileManager.destinationOfSymbolicLink(atPath: linkPath.path)
                    if !fileManager.fileExists(atPath: destination) {
                        brokenSymlinks.append(relativePath)
                    }
                } catch {
                    // a real directory instead of a link, fine too
                    continue
                }
            }
        }

        return ContainerValidationResult(
            isValid: missingDirectories.isEmpty && brokenSymlinks.isEmpty,
            missingDirectories: missingDirectories,
            brokenSymlinks: brokenSymlinks
        )
    }
}

struct ContainerValidationResult: Sendable {
    let isValid: Bool
    let missingDirectories: [String]
    let brokenSymlinks: [String]

    var issues: [String] {
        var result: [String] = []

        for dir in missingDirectories {
            result.append("Missing directory: \(dir)")
        }

        for link in brokenSymlinks {
            result.append("Broken symlink: \(link)")
        }

        return result
    }
}

// MARK: - Errors

enum ContainerError: LocalizedError {
    case creationFailed(URL, Error)
    case symlinkFailed(URL, URL)
    case invalidPath(URL)
    case permissionDenied(URL)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let url, let error):
            return "Failed to create container at \(url.path): \(error.localizedDescription)"
        case .symlinkFailed(let link, let target):
            return "Failed to create symlink from \(link.path) to \(target.path)"
        case .invalidPath(let url):
            return "Invalid container path: \(url.path)"
        case .permissionDenied(let url):
            return "Permission denied: \(url.path)"
        }
    }
}
