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

/// Starts apps with their own environment. The original binary and its signature stay untouched,
/// so CEF/Electron anti-tamper checks have nothing to complain about.
actor DirectLauncher {
    
    static let shared = DirectLauncher()
    
    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "DirectLauncher")
    private let fileManager = FileManager.default
    
    private init() {}
    
    @discardableResult
    func launch(_ instance: AppInstance) async throws -> NSRunningApplication {
        logger.info("Launching instance with NSWorkspace: \(instance.name)")
        
        let targetAppPath = instance.launchAppPath
        // A starter has its own bundle ID and no URL schemes, so it can stay registered
        let unregistersCopy = instance.privateCopy.map { !$0.isStarter } ?? false
        let dataPath = instance.isolationRoot
        let redirectsHome = instance.redirectsHome
        let maintainedFolder = instance.maintainedFolder
        let instanceId = instance.id
        let instanceName = instance.name
        let envVars = instance.effectiveEnvironmentVariables
        // The start script of a copy or starter adds the arguments itself
        let cmdArgs = instance.privateCopy.map { _ in [] } ?? instance.effectiveCommandLineArguments
        
        guard fileManager.fileExists(atPath: targetAppPath.path) else {
            throw DirectLaunchError.appNotFound(targetAppPath)
        }
        
        // with HOME redirected I build the fake home, otherwise just check the drive is there
        if redirectsHome {
            try prepareDataDirectory(dataPath: dataPath)
        } else if let volume = DataLocation.unmountedVolume(for: dataPath) {
            throw DirectLaunchError.dataVolumeUnavailable(volume)
        }
        
        // FAT/exFAT "._*" companion files break apps that wipe folders on startup
        if let folder = maintainedFolder, FileManager.default.fileExists(atPath: folder.path),
           AppleDoubleCleaner.needsCleanup(at: folder) {
            let removed = AppleDoubleCleaner.removeAppleDoubleFiles(in: folder)
            logger.info("Removed \(removed) AppleDouble files before launching \(instanceName)")
        }
        
        // The preferences shim must be in place before the app loads it
        if instance.separatePreferences == true {
            try PreferencesIsolation.installShim()
            try PreferencesIsolation.seedPreferences(for: instance)
        }
        
        let runningApp: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let workspace = NSWorkspace.shared
                
                let config = NSWorkspace.OpenConfiguration()
                config.environment = envVars
                config.arguments = cmdArgs
                config.activates = true
                config.createsNewApplicationInstance = true  // otherwise macOS just activates the running one
                
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
        
        // LaunchServices registers the copy once it runs. I unregister it again so the bundle ID and
        // URL schemes point to the original
        if unregistersCopy {
            Task.detached {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                PrivateCopyBuilder.unregisterFromLaunchServices(targetAppPath)
            }
        }
        
        runningApps[instanceId] = runningApp
        
        await MainActor.run {
            NotificationCenter.default.post(
                name: .instanceLaunched,
                object: nil,
                userInfo: ["instanceId": instanceId]
            )
        }
        
        logger.info("Successfully launched \(instanceName) with PID: \(runningApp.processIdentifier)")
        
        startMonitoring(instanceId: instanceId, app: runningApp)
        
        return runningApp
    }
    
    // MARK: - Process Management
    
    private var runningApps: [UUID: NSRunningApplication] = [:]
    
    func isRunning(_ instanceId: UUID) -> Bool {
        guard let app = runningApps[instanceId] else {
            return false
        }
        return !app.isTerminated
    }
    
    /// For instances started elsewhere (before PluralMac Plus was opened, or by a launcher app)
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
    
    func runningPID(_ instanceId: UUID) -> pid_t? {
        guard let app = runningApps[instanceId], !app.isTerminated else { return nil }
        return app.processIdentifier
    }
    
    func terminate(_ instanceId: UUID) -> Bool {
        guard let app = runningApps[instanceId], !app.isTerminated else {
            return false
        }
        
        return app.terminate()
    }
    
    func forceTerminate(_ instanceId: UUID) -> Bool {
        guard let app = runningApps[instanceId], !app.isTerminated else {
            return false
        }
        
        return app.forceTerminate()
    }
    
    func runningInstanceIds() -> [UUID] {
        runningApps = runningApps.filter { !$0.value.isTerminated }
        return Array(runningApps.keys)
    }
    
    private func startMonitoring(instanceId: UUID, app: NSRunningApplication) {
        Task { @MainActor in
            // polling is simpler than KVO from inside an actor
            while !app.isTerminated {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            
            await self.handleAppTermination(instanceId: instanceId)
        }
    }
    
    private func handleAppTermination(instanceId: UUID) {
        logger.info("Instance \(instanceId.uuidString) terminated")
        runningApps.removeValue(forKey: instanceId)
        
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .instanceTerminated,
                object: nil,
                userInfo: ["instanceId": instanceId]
            )
        }
    }
    
    /// Builds the fake home for HOME redirection (launcher apps use it too)
    func prepareDataDirectory(dataPath: URL) throws {
        // Don't silently start with an empty profile when the data lives on an unplugged drive
        if let volume = DataLocation.unmountedVolume(for: dataPath) {
            throw DirectLaunchError.dataVolumeUnavailable(volume)
        }
        
        if !fileManager.fileExists(atPath: dataPath.path) {
            try fileManager.createDirectory(
                at: dataPath,
                withIntermediateDirectories: true
            )
            logger.debug("Created data directory: \(dataPath.path)")
        }
        
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        
        // real user folders stay shared; the keychain too, apps don't find it under a redirected HOME
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
