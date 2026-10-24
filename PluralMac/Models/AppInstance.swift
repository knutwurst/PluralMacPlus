//
//  AppInstance.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation

struct AppInstance: Identifiable, Codable, Hashable, Sendable {
    
    let id: UUID
    var name: String
    let targetBundleIdentifier: String
    let targetAppPath: URL
    let targetAppType: AppType
    
    /// `~/Library/PluralMac/Instances/{name}.app`
    var shortcutPath: URL
    
    /// `<Data Directory setting>/{id}/` at creation, can be moved later
    var dataPath: URL
    
    var environmentVariables: [String: String]
    var commandLineArguments: [String]
    
    /// nil = the app's own icon
    var customIconPath: URL?
    var launcherPath: URL?
    
    /// degrees, nil = original colors
    var launcherIconHue: Double?
    
    /// fake hardware UUID the app gets to see; nil = the real one
    var hardwareIDOverride: UUID?
    
    /// UserDefaults in the instance folder instead of the shared ~/Library/Preferences
    var separatePreferences: Bool?
    
    /// runs instead of the original when set
    var privateCopy: PrivateAppCopy?
    
    /// Existing profile for argument-isolated apps (--user-data-dir, -profile); nil = data folder.
    /// PluralMac Plus never writes into it, only the app does.
    var profilePath: URL?
    
    /// nil = whatever the app type asks for
    var isolationMethodOverride: DataIsolationMethod?
    
    /// wipe the data when the app quits (labs, classrooms)
    var eraseDataOnQuit: Bool
    var showMenuBarIcon: Bool
    var notes: String?
    let createdAt: Date
    var modifiedAt: Date
    var lastLaunchedAt: Date?
    
    /// `dataPath` wins over `dataDirectory`; an existing folder is reused as is.
    init(
        name: String,
        application: Application,
        baseDirectory: URL = Self.defaultBaseDirectory,
        dataDirectory: URL = DataLocation.baseDirectory(),
        dataPath: URL? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.targetBundleIdentifier = application.bundleIdentifier
        self.targetAppPath = application.path
        self.targetAppType = application.appType
        
        let sanitizedName = Self.sanitizeFileName(name)
        self.shortcutPath = baseDirectory
            .appendingPathComponent("Instances")
            .appendingPathComponent("\(sanitizedName).app")
        
        self.dataPath = dataPath ?? dataDirectory
            .appendingPathComponent(id.uuidString)
        
        self.environmentVariables = [:]
        self.commandLineArguments = []
        self.customIconPath = nil
        self.launcherPath = nil
        self.launcherIconHue = nil
        self.hardwareIDOverride = nil
        self.isolationMethodOverride = nil
        self.eraseDataOnQuit = false
        self.showMenuBarIcon = false
        self.notes = nil
        
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.lastLaunchedAt = nil
    }
    
    // MARK: - Isolation
    
    var effectiveIsolationMethod: DataIsolationMethod {
        isolationMethodOverride ?? targetAppType.isolationMethod
    }
    
    /// where an argument-isolated app keeps its profile
    var appProfilePath: URL {
        profilePath ?? dataPath
    }
    
    /// Argument-isolated apps keep everything in their profile anyway. A re-signed copy would only
    /// cost them their keychain items.
    var canUsePrivateCopy: Bool {
        effectiveIsolationMethod != .userDataDir && effectiveIsolationMethod != .profileArgument
    }
    
    var launchAppPath: URL {
        privateCopy?.path ?? targetAppPath
    }
    
    /// a starter runs the original's binary
    var codeAppPath: URL {
        privateCopy?.isStarter == true ? targetAppPath : launchAppPath
    }
    
    /// a starter execs the original binary, so macOS lists the process under the original app
    var runningBundlePaths: [URL] {
        privateCopy?.isStarter == true ? [launchAppPath, targetAppPath] : [launchAppPath]
    }
    
    var shortcutExists: Bool {
        FileManager.default.fileExists(atPath: shortcutPath.path)
    }
    
    var dataDirectoryExists: Bool {
        FileManager.default.fileExists(atPath: dataPath.path)
    }
    
    /// Argument-isolated apps keep the real HOME. A redirected HOME hides the login keychain, new
    /// items (Electron's safe storage key) fail and the app falls back to an unencrypted key.
    var redirectsHome: Bool {
        isolationArguments.isEmpty
    }
    
    /// data folder (as HOME) or profile folder
    var isolationRoot: URL {
        redirectsHome ? dataPath : appProfilePath
    }
    
    /// what PluralMac Plus may clean up before launch. Never a profile the user picked.
    var maintainedFolder: URL? {
        redirectsHome || profilePath == nil ? dataPath : nil
    }
    
    var effectiveEnvironmentVariables: [String: String] {
        var env = environmentVariables
        
        if redirectsHome {
            env["HOME"] = dataPath.path
            
            // Foundation ignores HOME for NSHomeDirectory, Caches, Application Support and HTTPStorages.
            // CFFIXED_USER_HOME catches those.
            env["CFFIXED_USER_HOME"] = dataPath.path
            
            env["XDG_CONFIG_HOME"] = dataPath.appendingPathComponent(".config").path
            env["XDG_DATA_HOME"] = dataPath.appendingPathComponent(".local/share").path
            env["XDG_CACHE_HOME"] = dataPath.appendingPathComponent(".cache").path
        }
        
        // cfprefsd ignores HOME and CFFIXED_USER_HOME, so UserDefaults need the shim
        if separatePreferences == true {
            env["DYLD_INSERT_LIBRARIES"] = PreferencesIsolation.installedShimURL.path
            env[PreferencesIsolation.fileEnvironmentKey] = PreferencesIsolation.preferencesFile(for: self).path
        }
        
        // for apps that read their device ID from ioreg
        if let hardwareIDOverride {
            env[HardwareIdentity.environmentKey] = HardwareIdentity.ioregFunction(reporting: hardwareIDOverride)
        }
        
        return env
    }
    
    var effectiveCommandLineArguments: [String] {
        var args = commandLineArguments
        let bundleId = targetBundleIdentifier.lowercased()
        
        // Spotify: --mu for multiple instances
        if bundleId.contains("spotify") {
            args.append("--mu=\(id.uuidString)")
            return args
        }
        
        // Discord ignores --user-data-dir and HOME. --multi-instance only buys more windows on the
        // same account.
        if bundleId.contains("discord") {
            args.append("--multi-instance")
            return args
        }
        
        return args + isolationArguments
    }
    
    /// empty = isolated via HOME
    var isolationArguments: [String] {
        let bundleId = targetBundleIdentifier.lowercased()
        if bundleId.contains("spotify") || bundleId.contains("discord") {
            return []
        }
        // Slack, whatever type it got detected as
        if bundleId.contains("slack") {
            return ["--user-data-dir=\(appProfilePath.path)"]
        }
        switch effectiveIsolationMethod {
        case .userDataDir:
            return ["--user-data-dir=\(appProfilePath.path)"]
        case .profileArgument:
            return ["-profile", appProfilePath.path]
        case .homeRedirection, .none:
            return []
        }
    }
    
    nonisolated static var defaultBaseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("PluralMac")
    }
    
    // MARK: - Mutating
    
    mutating func touch() {
        modifiedAt = Date()
    }
    
    mutating func recordLaunch() {
        lastLaunchedAt = Date()
        touch()
    }
    
    mutating func rename(to newName: String, baseDirectory: URL = Self.defaultBaseDirectory) {
        name = newName
        let sanitizedName = Self.sanitizeFileName(newName)
        shortcutPath = baseDirectory
            .appendingPathComponent("Instances")
            .appendingPathComponent("\(sanitizedName).app")
        touch()
    }
    
    mutating func setEnvironmentVariable(_ key: String, value: String) {
        environmentVariables[key] = value
        touch()
    }
    
    mutating func removeEnvironmentVariable(_ key: String) {
        environmentVariables.removeValue(forKey: key)
        touch()
    }
    
    mutating func addArgument(_ argument: String) {
        if !commandLineArguments.contains(argument) {
            commandLineArguments.append(argument)
            touch()
        }
    }
    
    mutating func removeArgument(_ argument: String) {
        commandLineArguments.removeAll { $0 == argument }
        touch()
    }
    
    // MARK: - Helpers
    
    static func instance(usingDataPath dataPath: URL, in instances: [AppInstance]) -> AppInstance? {
        let path = dataPath.standardizedFileURL.path
        return instances.first { $0.dataPath.standardizedFileURL.path == path }
    }
    
    /// trimmed, nil if blank
    static func validatedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    
    nonisolated static func sanitizeFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        let sanitized = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return sanitized.isEmpty ? "Instance" : sanitized
    }
}

// MARK: - Codable

extension AppInstance {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case targetBundleIdentifier
        case targetAppPath
        case targetAppType
        case shortcutPath
        case dataPath
        case environmentVariables
        case commandLineArguments
        case customIconPath
        case launcherPath
        case launcherIconHue
        case hardwareIDOverride
        case separatePreferences
        case privateCopy
        case profilePath
        case isolationMethodOverride
        case eraseDataOnQuit
        case showMenuBarIcon
        case createdAt
        case modifiedAt
        case lastLaunchedAt
    }
}

// MARK: - Display

extension AppInstance {
    var createdAtFormatted: String {
        Self.dateFormatter.string(from: createdAt)
    }
    
    var lastLaunchedAtFormatted: String? {
        guard let date = lastLaunchedAt else { return nil }
        return Self.dateFormatter.string(from: date)
    }
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
