//
//  AppleDoubleCleaner.swift
//  PluralMac
//
//  Created by Knutwurst on 14.10.26.
//

import Foundation

/// Removes AppleDouble files ("._name") from instance folders on FAT/exFAT volumes.
///
/// Those file systems can't store extended attributes, so macOS keeps them in "._name" companion
/// files and deletes the companion together with the file. Apps that delete folders recursively
/// (enumerate first, then delete) then fail on the companion that already disappeared. Apps from
/// the internet get com.apple.provenance on every file they write, so this happens constantly.
nonisolated enum AppleDoubleCleaner {

    /// File systems that store extended attributes in AppleDouble files
    static func isAppleDoubleFileSystem(_ type: String) -> Bool {
        ["exfat", "msdos"].contains(type.lowercased())
    }

    /// Whether `url` lives on such a file system
    static func needsCleanup(at url: URL) -> Bool {
        var existing = url
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            existing.deleteLastPathComponent()
        }
        var info = statfs()
        guard statfs(existing.path, &info) == 0 else { return false }
        let type = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return isAppleDoubleFileSystem(type)
    }

    /// Deletes every "._*" file below `folder`; returns how many were removed.
    /// Uses find(1): FileManager hides "._" files, so it can't see what it should delete.
    @discardableResult
    static func removeAppleDoubleFiles(in folder: URL) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = [folder.path, "-name", "._*", "-type", "f", "-print", "-delete"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").count
    }
}
