//
//  CompatibilityDatabase.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import OSLog

/// Per-app compatibility notes, read from the bundled compatibility.json.
actor CompatibilityDatabase {

    static let shared = CompatibilityDatabase()

    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "CompatibilityDatabase")
    private var entries: [String: CompatibilityEntry] = [:]
    private var isLoaded = false

    // MARK: - Models

    struct CompatibilityEntry: Codable {
        let bundleIdentifier: String
        let name: String
        let appType: String
        let compatibilityLevel: String
        let isolationMethod: String
        let recommendedArguments: [String]
        let notes: String
        let testedVersion: String

        // the JSON has grown a few spellings over time, hence the aliases
        var appTypeEnum: AppType {
            switch appType {
            case "chromium", "chromiumBased": return .chromium
            case "firefox", "firefoxBased": return .firefox
            case "electron", "electronBased": return .electron
            case "toDesktop": return .toDesktop
            case "sandboxed": return .sandboxed
            case "system": return .system
            default: return .generic
            }
        }

        var compatibilityLevelEnum: CompatibilityLevel {
            switch compatibilityLevel {
            case "full": return .full
            case "partial": return .partial
            case "unsupported": return .unsupported
            default: return .partial
            }
        }

        var isolationMethodEnum: DataIsolationMethod {
            switch isolationMethod {
            case "userDataDir": return .userDataDir
            case "profile", "profileArgument": return .profileArgument
            case "homeRedirection": return .homeRedirection
            case "none": return .none
            default: return .homeRedirection
            }
        }
    }

    private struct DatabaseFile: Codable {
        let version: Int
        let lastUpdated: String
        let applications: [CompatibilityEntry]
    }

    private init() {}

    // MARK: - Loading

    /// Loads once. A missing or broken file counts as loaded too, so I don't retry on every query.
    func load() async {
        guard !isLoaded else { return }

        guard let url = Bundle.main.url(forResource: "compatibility", withExtension: "json") else {
            logger.warning("Compatibility database not found in bundle")
            isLoaded = true
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let database = try JSONDecoder().decode(DatabaseFile.self, from: data)

            // keyed by lowercased bundle ID; a duplicate ID in the JSON traps here
            entries = Dictionary(
                uniqueKeysWithValues: database.applications.map { ($0.bundleIdentifier.lowercased(), $0) }
            )

            isLoaded = true
            logger.info("Loaded compatibility database with \(database.applications.count) entries")
        } catch {
            logger.error("Failed to load compatibility database: \(error.localizedDescription)")
            isLoaded = true
        }
    }

    // MARK: - Queries

    func entry(for bundleId: String) async -> CompatibilityEntry? {
        await load()
        return entries[bundleId.lowercased()]
    }

    func isKnown(bundleId: String) async -> Bool {
        await entry(for: bundleId) != nil
    }

    /// Unknown apps come back as .partial.
    func compatibilityLevel(for bundleId: String) async -> CompatibilityLevel {
        if let entry = await entry(for: bundleId) {
            return entry.compatibilityLevelEnum
        }
        return .partial
    }

    func recommendedSettings(for bundleId: String) async -> (AppType, DataIsolationMethod, [String])? {
        guard let entry = await entry(for: bundleId) else { return nil }

        return (
            entry.appTypeEnum,
            entry.isolationMethodEnum,
            entry.recommendedArguments
        )
    }

    func apps(ofType type: AppType) async -> [CompatibilityEntry] {
        await load()
        return entries.values.filter { $0.appTypeEnum == type }
    }

    func fullyCompatibleApps() async -> [CompatibilityEntry] {
        await load()
        return entries.values.filter { $0.compatibilityLevelEnum == .full }
    }

    func notes(for bundleId: String) async -> String? {
        await entry(for: bundleId)?.notes
    }
}

extension Application {

    /// Database entry if there is one, otherwise whatever the detected app type implies.
    func checkCompatibility() async -> (level: CompatibilityLevel, notes: String?) {
        let db = CompatibilityDatabase.shared

        if let entry = await db.entry(for: bundleIdentifier) {
            return (entry.compatibilityLevelEnum, entry.notes)
        }

        return (appType.compatibilityLevel, nil)
    }
}
