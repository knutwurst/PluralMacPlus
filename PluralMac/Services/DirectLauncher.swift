//
//  DirectLauncher.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import AppKit
import OSLog

/// Service responsible for launching apps directly as child processes
/// with custom environment variables. This approach:
/// 1. Does NOT modify the original app binary
/// 2. Does NOT require creating bundles
/// 3. Preserves the original code signature
/// 4. Avoids anti-tampering protections in CEF/Electron apps
actor DirectLauncher {
    
    // MARK: - Singleton
    
    static let shared = DirectLauncher()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "DirectLauncher")
    private let fileManager = FileManager.default
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Launch
    
    /// Launch an app instance with modified environment using NSWorkspace
    /// - Parameter instance: The app instance to launch
    /// - Returns: The NSRunningApplication for tracking
    /// - Throws: DirectLaunchError if launch fails
    @discardableResult
    func launch(_ instance: AppInstance) async throws -> NSRunningApplication {
        logger.info("Launching instance with NSWorkspace: \(instance.name)")
        
        // Capture values from instance
        let targetAppPath = instance.launchAppPath
        let usesPrivateCopy = instance.privateCopy != nil
        let dataPath = instance.dataPath
        let instanceId = instance.id
        let instanceName = instance.name
        let envVars = instance.effectiveEnvironmentVariables
        let cmdArgs = instance.effectiveCommandLineArguments
        
        // Validate target app exists
        guard fileManager.fileExists(atPath: targetAppPath.path) else {
            throw DirectLaunchError.appNotFound(targetAppPath)
        }
        
        // Ensure data directory exists
        try prepareDataDirectory(dataPath: dataPath)
        
        // On FAT/exFAT, companion "._*" files break apps that delete folders on startup
        if AppleDoubleCleaner.needsCleanup(at: dataPath) {
            let removed = AppleDoubleCleaner.removeAppleDoubleFiles(in: dataPath)
            logger.info("Removed \(removed) AppleDouble files before launching \(instanceName)")
        }
        
        // The preferences shim must be in place before the app loads it
        if instance.separatePreferences == true {
            try PreferencesIsolation.installShim()
            try PreferencesIsolation.seedPreferences(for: instance)
        }
        
        // Launch using NSWorkspace - use continuation for callback-based API
        let runningApp: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let workspace = NSWorkspace.shared
                
                // Create configuration with environment variables
                let config = NSWorkspace.OpenConfiguration()
                config.environment = envVars
                config.arguments = cmdArgs
                config.activates = true
                config.createsNewApplicationInstance = true  // Key! Creates new instance
                
                workspace.openApplication(
                    at: targetAppPath,
                    configuration: config
                ) { app, error in
                    if let error = error {
                        continuation.resume(throwing: DirectLaunchError.launchFailed(error.localizedDescription))
                    } else if let app = app {
                        continuation.resume(returning: app)
                    } else {
                        continuation.resume(throwing: DirectLaunchError.launchFailed("No application returned"))
                    }
                }
            }
        }
        
        // Launching registers the copy with LaunchServices once the app has started; unregister it
        // afterwards so bundle ID and URL schemes point to the original again
        if usesPrivateCopy {
            Task.detached {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                PrivateCopyBuilder.unregisterFromLaunchServices(targetAppPath)
            }
        }
        
        // Store the running app
        runningApps[instanceId] = runningApp
        
        // Post notification for UI update
        await MainActor.run {
            NotificationCenter.default.post(
                name: .instanceLaunched,
                object: nil,
                userInfo: ["instanceId": instanceId]
            )
        }
        
        logger.info("Successfully launched \(instanceName) with PID: \(runningApp.processIdentifier)")
        
        // Start monitoring for termination
        startMonitoring(instanceId: instanceId, app: runningApp)
        
        return runningApp
    }
    
    // MARK: - Process Management
    
    /// Active running apps by instance ID
    private var runningApps: [UUID: NSRunningApplication] = [:]
    
    /// Check if an instance is running
    func isRunning(_ instanceId: UUID) -> Bool {
        guard let app = runningApps[instanceId] else {
            return false
        }
        return !app.isTerminated
    }
    
    /// Track an instance process that was started elsewhere (before PluralMac Plus was opened, or by a launcher app)
    func adopt(_ instanceId: UUID, pid: pid_t) {
        guard !isRunning(instanceId),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return
        }
        
        runningApps[instanceId] = app
        logger.info("Found running instance \(instanceId.uuidString) (PID: \(pid))")
        
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .instanceLaunched,
                object: nil,
                userInfo: ["instanceId": instanceId]
            )
        }
        
        startMonitoring(instanceId: instanceId, app: app)
    }
    
    /// Process ID of a running instance
    func runningPID(_ instanceId: UUID) -> pid_t? {
        guard let app = runningApps[instanceId], !app.isTerminated else { return nil }
        return app.processIdentifier
    }
    
    /// Get the running app for an instance
    func getRunningApp(_ instanceId: UUID) -> NSRunningApplication? {
        runningApps[instanceId]
    }
    
    /// Terminate a running instance
    func terminate(_ instanceId: UUID) -> Bool {
        guard let app = runningApps[instanceId], !app.isTerminated else {
            return false
        }
        
        return app.terminate()
    }
    
    /// Force terminate a running instance (SIGKILL)
    func forceTerminate(_ instanceId: UUID) -> Bool {
        guard let app = runningApps[instanceId], !app.isTerminated else {
            return false
        }
        
        return app.forceTerminate()
    }
    
    /// Get all running instance IDs
    func runningInstanceIds() -> [UUID] {
        // Clean up terminated apps first
        runningApps = runningApps.filter { !$0.value.isTerminated }
        return Array(runningApps.keys)
    }
    
    /// Get count of running instances
    func runningCount() -> Int {
        runningApps.filter { !$0.value.isTerminated }.count
    }
    
    /// Start monitoring an app for termination
    private func startMonitoring(instanceId: UUID, app: NSRunningApplication) {
        // Use KVO to monitor termination
        Task { @MainActor in
            // Poll for termination (simpler than KVO in actor context)
            while !app.isTerminated {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }
            
            // App terminated
            await self.handleAppTermination(instanceId: instanceId)
        }
    }
    
    /// Handle app termination
    private func handleAppTermination(instanceId: UUID) {
        logger.info("Instance \(instanceId.uuidString) terminated")
        runningApps.removeValue(forKey: instanceId)
        
        // Post notification for UI update
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .instanceTerminated,
                object: nil,
                userInfo: ["instanceId": instanceId]
            )
        }
    }
    
    /// Create the data directory with the HOME redirection layout (also used for launcher apps)
    func prepareDataDirectory(dataPath: URL) throws {
        // Don't silently start with an empty profile when the data lives on an unplugged drive
        if let volume = DataLocation.unmountedVolume(for: dataPath) {
            throw DirectLaunchError.dataVolumeUnavailable(volume)
        }
        
        // Create data directory if it doesn't exist
        if !fileManager.fileExists(atPath: dataPath.path) {
            try fileManager.createDirectory(
                at: dataPath,
                withIntermediateDirectories: true
            )
            logger.debug("Created data directory: \(dataPath.path)")
        }
        
        // Create essential symlinks for HOME redirection
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        
        // User folders - link to real locations
        let symlinks: [(String, String)] = [
            ("Desktop", "Desktop"),
            ("Documents", "Documents"),
            ("Downloads", "Downloads"),
            ("Movies", "Movies"),
            ("Music", "Music"),
            ("Pictures", "Pictures"),
            ("Public", "Public"),
            ("Library/Keychains", "Library/Keychains"),
        ]
        
        for (relativePath, targetRelativePath) in symlinks {
            let linkPath = dataPath.appendingPathComponent(relativePath)
            let targetPath = homeDirectory.appendingPathComponent(targetRelativePath)
            
            // Create parent directory if needed
            let parentDir = linkPath.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            
            // Create symlink if target exists and link doesn't
            if fileManager.fileExists(atPath: targetPath.path) &&
               !fileManager.fileExists(atPath: linkPath.path) {
                try fileManager.createSymbolicLink(at: linkPath, withDestinationURL: targetPath)
                logger.debug("Created symlink: \(relativePath) -> \(targetPath.path)")
            }
        }
        
        // Create Library subdirectories
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
    }
}

// MARK: - Errors

enum DirectLaunchError: LocalizedError {
    case appNotFound(URL)
    case invalidBundle(URL)
    case launchFailed(String)
    case alreadyRunning(UUID)
    case dataVolumeUnavailable(URL)
    
    var errorDescription: String? {
        switch self {
        case .appNotFound(let url):
            return "Application not found at: \(url.path)"
        case .invalidBundle(let url):
            return "Invalid application bundle: \(url.path)"
        case .launchFailed(let message):
            return "Failed to launch: \(message)"
        case .alreadyRunning(let id):
            return "Instance \(id.uuidString) is already running"
        case .dataVolumeUnavailable(let volume):
            return "The data folder is on \(volume.lastPathComponent), which is not connected. Connect the drive and try again."
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let instanceTerminated = Notification.Name("com.knutwurst.pluralmacplus.instanceTerminated")
    static let instanceLaunched = Notification.Name("com.knutwurst.pluralmacplus.instanceLaunched")
}
