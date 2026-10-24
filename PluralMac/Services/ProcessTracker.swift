//
//  ProcessTracker.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import AppKit
import OSLog
import Combine

/// Keeps track of which instances PluralMac launched and whether they're still alive.
@MainActor
final class ProcessTracker: ObservableObject {

    static let shared = ProcessTracker()

    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "ProcessTracker")

    @Published private(set) var runningInstances: [UUID: NSRunningApplication] = [:]

    private var terminationObserver: NSObjectProtocol?

    private init() {
        setupTerminationObserver()
    }

    deinit {
        if let observer = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func setupTerminationObserver() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor in
                self?.handleAppTermination(app)
            }
        }
    }

    private func handleAppTermination(_ app: NSRunningApplication) {
        // match by PID, the bundle ID isn't unique across instances
        for (instanceId, runningApp) in runningInstances {
            if runningApp.processIdentifier == app.processIdentifier {
                runningInstances.removeValue(forKey: instanceId)
                logger.info("Instance terminated: \(instanceId)")

                NotificationCenter.default.post(
                    name: .instanceDidTerminate,
                    object: nil,
                    userInfo: ["instanceId": instanceId]
                )
                break
            }
        }
    }

    // MARK: - Tracking

    func track(instanceId: UUID, app: NSRunningApplication) {
        runningInstances[instanceId] = app
        logger.info("Now tracking instance: \(instanceId) (PID: \(app.processIdentifier))")

        NotificationCenter.default.post(
            name: .instanceDidLaunch,
            object: nil,
            userInfo: ["instanceId": instanceId, "pid": app.processIdentifier]
        )
    }

    /// Also drops the entry if the process died and the termination notification never came.
    func isRunning(_ instanceId: UUID) -> Bool {
        guard let app = runningInstances[instanceId] else {
            return false
        }

        if app.isTerminated {
            runningInstances.removeValue(forKey: instanceId)
            return false
        }

        return true
    }

    func runningApp(for instanceId: UUID) -> NSRunningApplication? {
        guard let app = runningInstances[instanceId], !app.isTerminated else {
            runningInstances.removeValue(forKey: instanceId)
            return nil
        }
        return app
    }

    func processId(for instanceId: UUID) -> pid_t? {
        runningApp(for: instanceId)?.processIdentifier
    }

    // MARK: - Control

    /// Polite quit. The app may still say no.
    @discardableResult
    func terminate(_ instanceId: UUID) -> Bool {
        guard let app = runningApp(for: instanceId) else {
            logger.warning("Cannot terminate: instance \(instanceId) not running")
            return false
        }

        logger.info("Terminating instance: \(instanceId) (PID: \(app.processIdentifier))")

        let success = app.terminate()

        if success {
            logger.info("Termination initiated for instance: \(instanceId)")
        } else {
            logger.warning("Failed to terminate instance: \(instanceId)")
        }

        return success
    }

    /// SIGKILL, no unsaved-changes dialog.
    @discardableResult
    func forceTerminate(_ instanceId: UUID) -> Bool {
        guard let app = runningApp(for: instanceId) else {
            logger.warning("Cannot force terminate: instance \(instanceId) not running")
            return false
        }

        logger.info("Force terminating instance: \(instanceId) (PID: \(app.processIdentifier))")

        let success = app.forceTerminate()

        if success {
            runningInstances.removeValue(forKey: instanceId)
            logger.info("Force termination successful for instance: \(instanceId)")
        }

        return success
    }

    func terminateAll() {
        logger.info("Terminating all running instances")

        for instanceId in runningInstances.keys {
            terminate(instanceId)
        }
    }

    @discardableResult
    func activate(_ instanceId: UUID) -> Bool {
        guard let app = runningApp(for: instanceId) else {
            return false
        }

        return app.activate(options: [.activateIgnoringOtherApps])
    }

    @discardableResult
    func hide(_ instanceId: UUID) -> Bool {
        guard let app = runningApp(for: instanceId) else {
            return false
        }

        return app.hide()
    }

    /// Prunes dead entries before counting.
    var runningCount: Int {
        for (id, app) in runningInstances where app.isTerminated {
            runningInstances.removeValue(forKey: id)
        }
        return runningInstances.count
    }
}

extension Notification.Name {
    static let instanceDidLaunch = Notification.Name("com.knutwurst.PluralMacPlus.instanceDidLaunch")
    static let instanceDidTerminate = Notification.Name("com.knutwurst.PluralMacPlus.instanceDidTerminate")
}
