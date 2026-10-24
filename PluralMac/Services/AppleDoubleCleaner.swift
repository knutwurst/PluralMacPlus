//
//  AppleDoubleCleaner.swift
//  PluralMac
//
//  Created by Knutwurst on 14.10.26.
//

import Foundation

/// Removes AppleDouble "._name" files from instance folders on FAT/exFAT.
///
/// No xattrs there, so macOS keeps them in "._name" companions and deletes the companion along with
/// the file. Apps that enumerate a folder first and delete afterwards then trip over a companion that
/// is already gone. Downloaded apps tag every file they write with com.apple.provenance, so this
/// happens all the time. exFAT: the gift that keeps on giving.
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

    /// Deletes every "._*" below `folder` and returns the count. find(1), because FileManager hides
    /// "._" files and can't see what it should delete.
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
