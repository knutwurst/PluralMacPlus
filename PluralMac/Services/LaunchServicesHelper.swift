//
//  LaunchServicesHelper.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import CoreServices
import OSLog

/// Thin wrappers around LaunchServices and NSWorkspace.
struct LaunchServicesHelper: Sendable {

    private static let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "LaunchServices")

    // MARK: - Registration

    @discardableResult
    static func register(_ bundleURL: URL) -> Bool {
        let status = LSRegisterURL(bundleURL as CFURL, true)

        if status == noErr {
            logger.info("Successfully registered: \(bundleURL.lastPathComponent)")
            return true
        } else {
            logger.warning("Failed to register \(bundleURL.lastPathComponent): error \(status)")
            return false
        }
    }

    /// Returns how many registered successfully.
    static func registerAll(_ bundleURLs: [URL]) -> Int {
        var successCount = 0
        for url in bundleURLs {
            if register(url) {
                successCount += 1
            }
        }
        return successCount
    }

    // MARK: - App Info

    /// CFBundleDisplayName, then CFBundleName, then the file name.
    static func displayName(for bundleURL: URL) -> String? {
        guard let bundle = Bundle(url: bundleURL) else { return nil }

        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundleURL.deletingPathExtension().lastPathComponent
    }

    static func bundleIdentifier(for bundleURL: URL) -> String? {
        Bundle(url: bundleURL)?.bundleIdentifier
    }

    static func version(for bundleURL: URL) -> String? {
        guard let bundle = Bundle(url: bundleURL) else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    // MARK: - Launch

    /// Blocks the main thread on a semaphore until the app is up. Prefer launchAsync.
    @MainActor
    static func launch(
        _ bundleURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.environment = environment
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        var launchedApp: NSRunningApplication?
        var launchError: Error?

        let semaphore = DispatchSemaphore(value: 0)

        NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: configuration
        ) { app, error in
            launchedApp = app
            launchError = error
            semaphore.signal()
        }

        semaphore.wait()

        if let error = launchError {
            throw LaunchError.launchFailed(bundleURL, error)
        }

        guard let app = launchedApp else {
            throw LaunchError.noAppReturned(bundleURL)
        }

        logger.info("Launched: \(bundleURL.lastPathComponent)")
        return app
    }

    @MainActor
    static func launchAsync(
        _ bundleURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.environment = environment
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        do {
            let app = try await NSWorkspace.shared.openApplication(
                at: bundleURL,
                configuration: configuration
            )
            logger.info("Launched: \(bundleURL.lastPathComponent)")
            return app
        } catch {
            throw LaunchError.launchFailed(bundleURL, error)
        }
    }

    // MARK: - Finder

    @MainActor
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    @MainActor
    static func openContainingFolder(_ url: URL) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    // MARK: - Running Apps

    @MainActor
    static func isRunning(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    @MainActor
    static func runningInstances(bundleIdentifier: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    /// True if at least one instance accepted the quit request.
    @MainActor
    @discardableResult
    static func terminate(bundleIdentifier: String) -> Bool {
        let apps = runningInstances(bundleIdentifier: bundleIdentifier)
        var terminated = false

        for app in apps {
            if app.terminate() {
                terminated = true
            }
        }

        return terminated
    }

    @MainActor
    @discardableResult
    static func forceTerminate(bundleIdentifier: String) -> Bool {
        let apps = runningInstances(bundleIdentifier: bundleIdentifier)
        var terminated = false

        for app in apps {
            if app.forceTerminate() {
                terminated = true
            }
        }

        return terminated
    }
}

// MARK: - Errors

enum LaunchError: LocalizedError {
    case launchFailed(URL, Error)
    case noAppReturned(URL)
    case appNotFound(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let url, let error):
            return "Failed to launch \(url.lastPathComponent): \(error.localizedDescription)"
        case .noAppReturned(let url):
            return "No application returned after launching: \(url.lastPathComponent)"
        case .appNotFound(let identifier):
            return "Application not found: \(identifier)"
        }
    }
}

// down here for NSWorkspace / NSRunningApplication. Yes, at the bottom.
import AppKit
