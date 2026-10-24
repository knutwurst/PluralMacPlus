//
//  MenuBarManager.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import AppKit
import SwiftUI
import Combine
import OSLog

/// The optional status bar icon with a quick-launch menu.
@MainActor
final class MenuBarManager: NSObject, ObservableObject {

    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "MenuBarManager")

    @Published var isMenuBarIconVisible: Bool = false {
        didSet {
            if isMenuBarIconVisible {
                setupStatusItem()
            } else {
                removeStatusItem()
            }
        }
    }

    @Published var instances: [AppInstance] = []

    private override init() {
        super.init()
    }

    // MARK: - Status Item

    func setupStatusItem() {
        guard statusItem == nil else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "PluralMac Plus")
            button.image?.isTemplate = true
            button.toolTip = "PluralMac Plus - Quick Launch"
        }

        updateMenu()
        logger.info("Menu bar icon enabled")
    }

    func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            logger.info("Menu bar icon disabled")
        }
    }

    /// Rebuilds the whole menu from `instances`.
    func updateMenu() {
        let menu = NSMenu()

        let headerItem = NSMenuItem(title: "PluralMac Plus", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(NSMenuItem.separator())

        if instances.isEmpty {
            let noInstancesItem = NSMenuItem(title: "No instances", action: nil, keyEquivalent: "")
            noInstancesItem.isEnabled = false
            menu.addItem(noInstancesItem)
        } else {
            let grouped = Dictionary(grouping: instances) { $0.targetBundleIdentifier }

            for (bundleId, appInstances) in grouped.sorted(by: { $0.key < $1.key }) {
                if let firstInstance = appInstances.first {
                    let appName = firstInstance.targetAppPath.deletingPathExtension().lastPathComponent

                    // app headers only once there's more than one app to tell apart
                    if grouped.count > 1 {
                        let appHeader = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
                        appHeader.isEnabled = false
                        menu.addItem(appHeader)
                    }

                    for instance in appInstances.sorted(by: { $0.name < $1.name }) {
                        let item = NSMenuItem(
                            title: instance.name,
                            action: #selector(launchInstance(_:)),
                            keyEquivalent: ""
                        )
                        item.target = self
                        item.representedObject = instance

                        if instance.shortcutExists {
                            let icon = NSWorkspace.shared.icon(forFile: instance.shortcutPath.path)
                            icon.size = NSSize(width: 16, height: 16)
                            item.image = icon
                        }

                        menu.addItem(item)
                    }

                    if grouped.count > 1 {
                        menu.addItem(NSMenuItem.separator())
                    }
                }
            }
        }

        menu.addItem(NSMenuItem.separator())

        let createItem = NSMenuItem(
            title: "Create New Instance...",
            action: #selector(showCreateWindow),
            keyEquivalent: "n"
        )
        createItem.keyEquivalentModifierMask = [.command, .shift]
        createItem.target = self
        menu.addItem(createItem)

        menu.addItem(NSMenuItem.separator())

        let showWindowItem = NSMenuItem(
            title: "Show PluralMac Plus",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        showWindowItem.target = self
        menu.addItem(showWindowItem)

        let preferencesItem = NSMenuItem(
            title: "Preferences...",
            action: #selector(showPreferences),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit PluralMac Plus",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func launchInstance(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? AppInstance else { return }

        Task {
            do {
                // already running: just bring it to the front
                if let pid = await DirectLauncher.shared.runningPID(instance.id),
                   let app = NSRunningApplication(processIdentifier: pid) {
                    InstanceActivator.bringToFront(app)
                } else {
                    try await DirectLauncher.shared.launch(instance)
                    logger.info("Launched instance from menu bar: \(instance.name)")
                }
            } catch {
                logger.error("Failed to launch instance: \(error.localizedDescription)")
            }
        }
    }

    @objc private func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        // any window except SwiftUI's Settings window
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue != "com_apple_SwiftUI_Settings_window" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func showCreateWindow() {
        showMainWindow()

        NotificationCenter.default.post(name: .showCreateInstance, object: nil)
    }

    @objc private func showPreferences() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        // private selectors, no public API for this. 14+ wants showSettingsWindow:
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    func updateInstances(_ newInstances: [AppInstance]) {
        self.instances = newInstances
        updateMenu()
    }
}
