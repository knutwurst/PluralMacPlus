//
//  DataLocation.swift
//  PluralMac
//
//  Created by Knutwurst on 13.10.26.
//

import Foundation

/// Resolves where instance data folders live.
nonisolated enum DataLocation {

    /// UserDefaults key of the "Data Directory" setting (empty = default location)
    static let defaultsKey = "defaultDataDirectory"

    /// The "Data Directory" setting, or `~/Library/PluralMac/Data` when it's empty
    static func baseDirectory(defaults: UserDefaults = .standard) -> URL {
        let setting = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !setting.isEmpty else {
            return AppInstance.defaultBaseDirectory.appendingPathComponent("Data")
        }

        let expanded = (setting as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// `/Volumes/<name>` if `url` is on a volume that isn't mounted
    static func unmountedVolume(for url: URL) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else {
            return nil
        }

        let volume = URL(fileURLWithPath: "/Volumes").appendingPathComponent(components[2])
        return FileManager.default.fileExists(atPath: volume.path) ? nil : volume
    }
}
