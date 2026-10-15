//
//  AppInstance.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation

/// Represents a configured instance of an application with isolated data storage.
/// Each instance can have its own environment variables, command-line arguments,
/// custom icon, and data directory.
struct AppInstance: Identifiable, Codable, Hashable, Sendable {
    
    // MARK: - Properties
    
    /// Unique identifier for this instance
    let id: UUID
    
    /// User-defined display name for this instance
    var name: String
    
    /// Bundle identifier of the target application
    let targetBundleIdentifier: String
    
    /// Path to the original target application
    let targetAppPath: URL
    
    /// Type of the target application (for data isolation strategy)
    let targetAppType: AppType
    
    /// Path to the created shortcut bundle
    /// `~/Library/PluralMac/Instances/{name}.app`
    var shortcutPath: URL
    
    /// Path to the isolated data directory for this instance
    /// `<Data Directory setting>/{id}/` by default (`~/Library/PluralMac/Data/{id}/`),
    /// can be moved elsewhere afterwards
    var dataPath: URL
    
    /// Custom environment variables for this instance
    var environmentVariables: [String: String]
    
    /// Custom command-line arguments for this instance
    var commandLineArguments: [String]
    
    /// Path to custom icon (nil = use original app icon)
    var customIconPath: URL?
    
    /// Launcher app created for this instance (nil = none)
    var launcherPath: URL?
    
    /// Hue rotation in degrees applied to the launcher icon (nil = original colors)
    var launcherIconHue: Double?
    
    /// Hardware UUID reported to the app instead of the Mac's own (nil = real hardware UUID)
    var hardwareIDOverride: UUID?
    
    /// Keep UserDefaults in the instance folder (true) instead of the shared ~/Library/Preferences
    var separatePreferences: Bool?
    
    /// Private copy of the app the instance runs instead of the original (nil = original)
    var privateCopy: PrivateAppCopy?
    
    /// Existing app profile for apps isolated by argument (--user-data-dir, -profile); nil = data folder.
    /// PluralMac Plus never writes into it, only the app does.
    var profilePath: URL?
    
    /// Data isolation method override (nil = use default for app type)
    var isolationMethodOverride: DataIsolationMethod?
    
    /// Whether to erase data when the shortcut quits (for labs/education)
    var eraseDataOnQuit: Bool
    
    /// Whether to show a menu bar icon when running
    var showMenuBarIcon: Bool
    
    /// Optional notes/description for this instance
    var notes: String?
    
    /// Creation date
    let createdAt: Date
    
    /// Last modification date
    var modifiedAt: Date
    
    /// Last launch date (nil if never launched)
    var lastLaunchedAt: Date?
    
    // MARK: - Initialization
    
    /// Create a new app instance configuration
    /// - Parameters:
    ///   - name: Display name for the instance
    ///   - application: The target application to create an instance of
    ///   - baseDirectory: Base directory for PluralMac data (default: ~/Library/PluralMac)
    ///   - dataDirectory: Parent directory for the instance data folder (default: Data Directory setting)
    ///   - dataPath: Explicit data folder; overrides `dataDirectory` (an existing folder is reused as-is)
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
        
        // Generate paths
        let sanitizedName = Self.sanitizeFileName(name)
        self.shortcutPath = baseDirectory
            .appendingPathComponent("Instances")
            .appendingPathComponent("\(sanitizedName).app")
        
        self.dataPath = dataPath ?? dataDirectory
            .appendingPathComponent(id.uuidString)
        
        // Defaults
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
        
        // Timestamps
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.lastLaunchedAt = nil
    }
    
    // MARK: - Computed Properties
    
    /// The effective data isolation method (override or default for app type)
    var effectiveIsolationMethod: DataIsolationMethod {
        isolationMethodOverride ?? targetAppType.isolationMethod
    }
    
    /// Folder the app keeps its profile in when isolated by argument
    var appProfilePath: URL {
        profilePath ?? dataPath
    }
    
    /// Apps isolated by argument keep everything in their profile folder; a re-signed copy would
    /// only risk losing access to their keychain items
    var canUsePrivateCopy: Bool {
        effectiveIsolationMethod != .userDataDir && effectiveIsolationMethod != .profileArgument
    }
    
    /// The app bundle to launch: the private copy if there is one, otherwise the original
    var launchAppPath: URL {
        privateCopy?.path ?? targetAppPath
    }
    
    /// The bundle whose code actually runs (a starter runs the original's binary)
    var codeAppPath: URL {
        privateCopy?.isStarter == true ? targetAppPath : launchAppPath
    }
    
    /// Bundles a running process of this instance can report: a starter execs the original binary,
    /// so macOS lists that process under the original app
    var runningBundlePaths: [URL] {
        privateCopy?.isStarter == true ? [launchAppPath, targetAppPath] : [launchAppPath]
    }
    
    /// Check if the shortcut bundle exists
    var shortcutExists: Bool {
        FileManager.default.fileExists(atPath: shortcutPath.path)
    }
    
    /// Check if the data directory exists
    var dataDirectoryExists: Bool {
        FileManager.default.fileExists(atPath: dataPath.path)
    }
    
    /// Apps isolated by argument keep everything in their profile folder and run with the user's own
    /// HOME. A redirected HOME hides the login keychain from them: new keychain items (such as
    /// Electron's safe storage key) fail, and the app falls back to an unencrypted key.
    var redirectsHome: Bool {
        isolationArguments.isEmpty
    }
    
    /// The folder the instance's app writes into: the data folder (as HOME) or the profile folder
    var isolationRoot: URL {
        redirectsHome ? dataPath : appProfilePath
    }
    
    /// Folder PluralMac Plus may clean up before launch; never an existing profile chosen by the user
    var maintainedFolder: URL? {
        redirectsHome || profilePath == nil ? dataPath : nil
    }
    
    /// Get the complete environment variables including HOME override if needed
    var effectiveEnvironmentVariables: [String: String] {
        var env = environmentVariables
        
        if redirectsHome {
            // Redirect HOME so apps that build paths from it stay in the data folder
            env["HOME"] = dataPath.path
            
            // Foundation ignores HOME (NSHomeDirectory, Caches, Application Support, HTTPStorages);
            // CFFIXED_USER_HOME makes those follow the data folder as well. UserDefaults are not
            // affected: cfprefsd resolves the preferences folder itself.
            env["CFFIXED_USER_HOME"] = dataPath.path
            
            // Also set XDG directories for apps that use them
            env["XDG_CONFIG_HOME"] = dataPath.appendingPathComponent(".config").path
            env["XDG_DATA_HOME"] = dataPath.appendingPathComponent(".local/share").path
            env["XDG_CACHE_HOME"] = dataPath.appendingPathComponent(".cache").path
        }
        
        // Redirect UserDefaults into the data folder (cfprefsd ignores HOME and CFFIXED_USER_HOME)
        if separatePreferences == true {
            env["DYLD_INSERT_LIBRARIES"] = PreferencesIsolation.installedShimURL.path
            env[PreferencesIsolation.fileEnvironmentKey] = PreferencesIsolation.preferencesFile(for: self).path
        }
        
        // Apps that read their device ID from ioreg see a separate hardware UUID
        if let hardwareIDOverride {
            env[HardwareIdentity.environmentKey] = HardwareIdentity.ioregFunction(reporting: hardwareIDOverride)
        }
        
        return env
    }
    
    /// Get the complete command-line arguments including data isolation args
    var effectiveCommandLineArguments: [String] {
        var args = commandLineArguments
        let bundleId = targetBundleIdentifier.lowercased()
        
        // Spotify uses --mu for multiple instances
        if bundleId.contains("spotify") {
            args.append("--mu=\(id.uuidString)")
            return args
        }
        
        // Discord uses --multi-instance to allow multiple windows
        // NOTE: Discord does NOT support data isolation - it ignores --user-data-dir and HOME
        // All instances share the same account/data. This only allows multiple windows.
        if bundleId.contains("discord") {
            args.append("--multi-instance")
            return args
        }
        
        return args + isolationArguments
    }
    
    /// Arguments that point the app at this instance's profile folder (empty = isolated by HOME)
    var isolationArguments: [String] {
        let bundleId = targetBundleIdentifier.lowercased()
        if bundleId.contains("spotify") || bundleId.contains("discord") {
            return []
        }
        // Slack uses --user-data-dir
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
    
    /// Default base directory for PluralMac data
    nonisolated static var defaultBaseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("PluralMac")
    }
    
    // MARK: - Methods
    
    /// Update the modification timestamp
    mutating func touch() {
        modifiedAt = Date()
    }
    
    /// Record that the instance was launched
    mutating func recordLaunch() {
        lastLaunchedAt = Date()
        touch()
    }
    
    /// Rename the instance (updates name and shortcut path)
    mutating func rename(to newName: String, baseDirectory: URL = Self.defaultBaseDirectory) {
        name = newName
        let sanitizedName = Self.sanitizeFileName(newName)
        shortcutPath = baseDirectory
            .appendingPathComponent("Instances")
            .appendingPathComponent("\(sanitizedName).app")
        touch()
    }
    
    /// Set a custom environment variable
    mutating func setEnvironmentVariable(_ key: String, value: String) {
        environmentVariables[key] = value
        touch()
    }
    
    /// Remove an environment variable
    mutating func removeEnvironmentVariable(_ key: String) {
        environmentVariables.removeValue(forKey: key)
        touch()
    }
    
    /// Add a command-line argument
    mutating func addArgument(_ argument: String) {
        if !commandLineArguments.contains(argument) {
            commandLineArguments.append(argument)
            touch()
        }
    }
    
    /// Remove a command-line argument
    mutating func removeArgument(_ argument: String) {
        commandLineArguments.removeAll { $0 == argument }
        touch()
    }
    
    // MARK: - Private Helpers
    
    /// The instance in `instances` whose data folder is `dataPath`, if any
    static func instance(usingDataPath dataPath: URL, in instances: [AppInstance]) -> AppInstance? {
        let path = dataPath.standardizedFileURL.path
        return instances.first { $0.dataPath.standardizedFileURL.path == path }
    }
    
    /// Trimmed instance name, or nil if it is blank
    static func validatedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    
    /// Sanitize a string to be used as a file name
    nonisolated static func sanitizeFileName(_ name: String) -> String {
        // Remove/replace characters that are problematic in file names
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        let sanitized = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Ensure non-empty
        return sanitized.isEmpty ? "Instance" : sanitized
    }
}

// MARK: - Codable Conformance

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

// MARK: - Display Helpers

extension AppInstance {
    /// Formatted creation date string
    var createdAtFormatted: String {
        Self.dateFormatter.string(from: createdAt)
    }
    
    /// Formatted last launch date string
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
