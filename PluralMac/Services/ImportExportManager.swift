//
//  ImportExportManager.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import OSLog

/// Exports and imports instance settings as JSON. Settings only, no app data.
actor ImportExportManager {

    static let shared = ImportExportManager()

    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "ImportExportManager")
    private let fileManager = FileManager.default

    // MARK: - File Format

    struct ExportedInstance: Codable {
        let version: Int
        let exportDate: Date
        let name: String
        let targetAppPath: String
        let targetBundleIdentifier: String
        let environmentVariables: [String: String]
        let commandLineArguments: [String]
        let isolationMethodOverride: String?
        let eraseDataOnQuit: Bool
        let showMenuBarIcon: Bool
        let notes: String?

        init(from instance: AppInstance) {
            self.version = 1
            self.exportDate = Date()
            self.name = instance.name
            self.targetAppPath = instance.targetAppPath.path
            self.targetBundleIdentifier = instance.targetBundleIdentifier
            self.environmentVariables = instance.environmentVariables
            self.commandLineArguments = instance.commandLineArguments
            self.isolationMethodOverride = instance.isolationMethodOverride?.rawValue
            self.eraseDataOnQuit = instance.eraseDataOnQuit
            self.showMenuBarIcon = instance.showMenuBarIcon
            self.notes = instance.notes
        }
    }

    struct ExportBundle: Codable {
        let version: Int
        let exportDate: Date
        let appVersion: String
        let instances: [ExportedInstance]

        init(instances: [AppInstance]) {
            self.version = 1
            self.exportDate = Date()
            self.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            self.instances = instances.map { ExportedInstance(from: $0) }
        }
    }

    private init() {}

    // MARK: - Export

    func exportInstance(_ instance: AppInstance) throws -> Data {
        let exported = ExportedInstance(from: instance)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        return try encoder.encode(exported)
    }

    func exportInstances(_ instances: [AppInstance]) throws -> Data {
        let bundle = ExportBundle(instances: instances)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        return try encoder.encode(bundle)
    }

    func exportToFile(_ instances: [AppInstance], destination: URL) throws {
        let data = try exportInstances(instances)
        try data.write(to: destination)
        logger.info("Exported \(instances.count) instances to \(destination.path)")
    }

    // MARK: - Import

    /// Takes both a multi-instance bundle and a single exported instance.
    func importFromData(_ data: Data) throws -> [ImportedInstanceConfig] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let bundle = try? decoder.decode(ExportBundle.self, from: data) {
            return try bundle.instances.map { try ImportedInstanceConfig(from: $0) }
        }

        if let single = try? decoder.decode(ExportedInstance.self, from: data) {
            return [try ImportedInstanceConfig(from: single)]
        }

        throw ImportExportError.invalidFormat
    }

    func importFromFile(_ url: URL) throws -> [ImportedInstanceConfig] {
        let data = try Data(contentsOf: url)
        let configs = try importFromData(data)
        logger.info("Imported \(configs.count) instance configs from \(url.path)")
        return configs
    }

    /// Flags configs whose target app isn't installed on this Mac.
    func validateImport(_ configs: [ImportedInstanceConfig]) -> [ImportValidationResult] {
        configs.map { config in
            let appExists = fileManager.fileExists(atPath: config.targetAppPath.path)

            var warnings: [String] = []
            if !appExists {
                warnings.append("Target application not found: \(config.targetAppPath.path)")
            }

            return ImportValidationResult(
                config: config,
                isValid: appExists,
                warnings: warnings
            )
        }
    }
}

struct ImportedInstanceConfig {
    let name: String
    let targetAppPath: URL
    let targetBundleIdentifier: String
    let environmentVariables: [String: String]
    let commandLineArguments: [String]
    let isolationMethodOverride: DataIsolationMethod?
    let eraseDataOnQuit: Bool
    let showMenuBarIcon: Bool
    let notes: String?

    init(from exported: ImportExportManager.ExportedInstance) throws {
        self.name = exported.name
        self.targetAppPath = URL(fileURLWithPath: exported.targetAppPath)
        self.targetBundleIdentifier = exported.targetBundleIdentifier
        self.environmentVariables = exported.environmentVariables
        self.commandLineArguments = exported.commandLineArguments
        // unknown method names from newer versions silently become nil
        self.isolationMethodOverride = exported.isolationMethodOverride.flatMap { DataIsolationMethod(rawValue: $0) }
        self.eraseDataOnQuit = exported.eraseDataOnQuit
        self.showMenuBarIcon = exported.showMenuBarIcon
        self.notes = exported.notes
    }

    func createInstance() throws -> AppInstance {
        let application = try Application(from: targetAppPath)
        var instance = AppInstance(name: name, application: application)
        instance.environmentVariables = environmentVariables
        instance.commandLineArguments = commandLineArguments
        instance.isolationMethodOverride = isolationMethodOverride
        instance.eraseDataOnQuit = eraseDataOnQuit
        instance.showMenuBarIcon = showMenuBarIcon
        instance.notes = notes
        return instance
    }
}

struct ImportValidationResult {
    let config: ImportedInstanceConfig
    let isValid: Bool
    let warnings: [String]
}

// MARK: - Errors

enum ImportExportError: LocalizedError {
    case invalidFormat
    case versionMismatch(expected: Int, found: Int)
    case targetAppNotFound(String)
    case exportFailed(String)
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid import file format"
        case .versionMismatch(let expected, let found):
            return "Version mismatch: expected \(expected), found \(found)"
        case .targetAppNotFound(let path):
            return "Target application not found: \(path)"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .importFailed(let reason):
            return "Import failed: \(reason)"
        }
    }
}

