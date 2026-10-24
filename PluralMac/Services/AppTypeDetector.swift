//
//  AppTypeDetector.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import OSLog

/// Figures out what kind of app a bundle is (Chromium, Firefox, Electron, ...) and which
/// isolation flags fit it.
final class AppTypeDetector: Sendable {

    static let shared = AppTypeDetector()

    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "AppTypeDetector")

    // MARK: - Known Bundle IDs

    private let chromiumIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi",
        "com.vivaldi.Vivaldi.snapshot",
        "company.thebrowser.Browser", // Arc
        "org.chromium.Chromium",
        "com.operasoftware.Opera",
        "com.nicothin.nickel",
        "com.nicothin.nickel.dev",
        "com.nicothin.nickel.beta",
        "ru.nicothin.nickel",
        "io.nickel.nickel",
        "com.nickel.Nickel",
        "io.nickel.Nickel"
    ]

    private let firefoxIdentifiers: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "org.waterfox.waterfox",
        "org.waterfoxproject.waterfox",
        "io.gitlab.librewolf-community",
        "org.torproject.torbrowser",
        "net.mullvad.mullvadbrowser"
    ]

    private let toDesktopIdentifiers: Set<String> = [
        "com.todesktop.cursor",
        "todesktop.com.cursor",
        "com.linear.Linear",
        "com.todesktop.linear"
    ]

    // only the common ones, the rest gets caught by detectByBundleContents
    private let electronIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.hnc.DiscordPTB",
        "com.hnc.DiscordCanary",
        "notion.id",
        "com.spotify.client",
        "com.figma.Desktop",
        "md.obsidian",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.todoist.mac.Todoist",
        "com.postmanlabs.mac",
        "io.zsa.wally",
        "com.github.GitHubClient"
    ]

    private init() {}

    // MARK: - Detection

    func detect(at url: URL) -> AppType {
        logger.debug("Detecting app type for: \(url.path)")

        guard let bundle = Bundle(url: url) else {
            logger.warning("Invalid bundle at: \(url.path)")
            return .generic
        }

        guard let bundleId = bundle.bundleIdentifier else {
            logger.warning("No bundle identifier for: \(url.path)")
            return .generic
        }

        if bundleId.hasPrefix("com.apple.") {
            logger.info("System app detected: \(bundleId)")
            return .system
        }

        if isSandboxed(bundle: bundle) {
            logger.info("Sandboxed app detected: \(bundleId)")
            return .sandboxed
        }

        if let type = detectByIdentifier(bundleId) {
            logger.info("Known app detected: \(bundleId) -> \(type.rawValue)")
            return type
        }

        if let type = detectByBundleContents(bundle: bundle) {
            logger.info("App type detected by contents: \(bundleId) -> \(type.rawValue)")
            return type
        }

        logger.info("Generic app: \(bundleId)")
        return .generic
    }

    /// Heuristic: an App Store receipt or an embedded provisioning profile.
    func isSandboxed(bundle: Bundle) -> Bool {
        if let receiptURL = bundle.appStoreReceiptURL,
           FileManager.default.fileExists(atPath: receiptURL.path) {
            return true
        }

        let entitlementsPath = bundle.bundlePath + "/Contents/embedded.provisionprofile"
        if FileManager.default.fileExists(atPath: entitlementsPath) {
            return true
        }

        return false
    }

    func recommendedArguments(for appType: AppType, dataPath: URL) -> [String] {
        switch appType {
        case .chromium:
            return [
                "--user-data-dir=\(dataPath.path)",
                "--no-first-run"
            ]
        case .firefox:
            return [
                "-profile",
                dataPath.path,
                "-no-remote"
            ]
        case .electron, .toDesktop, .generic:
            // HOME redirection does the job, no flags
            return []
        case .sandboxed, .system:
            return []
        }
    }

    func recommendedEnvironment(for appType: AppType, dataPath: URL) -> [String: String] {
        switch appType {
        case .electron, .toDesktop, .generic:
            return ["HOME": dataPath.path]
        case .chromium:
            // --user-data-dir does most of it, HOME catches the leftovers
            return ["HOME": dataPath.path]
        case .firefox:
            // -profile is enough
            return [:]
        case .sandboxed, .system:
            return [:]
        }
    }

    // MARK: - Private

    private func detectByIdentifier(_ bundleId: String) -> AppType? {
        if chromiumIdentifiers.contains(bundleId) {
            return .chromium
        }

        if firefoxIdentifiers.contains(bundleId) {
            return .firefox
        }

        if toDesktopIdentifiers.contains(bundleId) {
            return .toDesktop
        }

        if electronIdentifiers.contains(bundleId) {
            return .electron
        }

        // prefix match for channel variants I don't list explicitly
        for id in chromiumIdentifiers {
            if bundleId.hasPrefix(id) {
                return .chromium
            }
        }

        for id in firefoxIdentifiers {
            if bundleId.hasPrefix(id) {
                return .firefox
            }
        }

        return nil
    }

    private func detectByBundleContents(bundle: Bundle) -> AppType? {
        let frameworksPath = bundle.bundlePath + "/Contents/Frameworks"

        // ToDesktop apps are Electron too, so check them first
        if isToDesktopApp(frameworksPath: frameworksPath, bundle: bundle) {
            return .toDesktop
        }

        if isElectronApp(frameworksPath: frameworksPath) {
            return .electron
        }

        // catches Chromium forks that aren't in the list
        if isChromiumApp(frameworksPath: frameworksPath) {
            return .chromium
        }

        return nil
    }

    private func isToDesktopApp(frameworksPath: String, bundle: Bundle) -> Bool {
        let fm = FileManager.default

        let toDesktopMarkers = [
            "ToDesktop Runtime Helper.app",
            "ToDesktopRuntimeHelper.app",
            "ToDesktop Helper.app"
        ]

        for marker in toDesktopMarkers {
            if fm.fileExists(atPath: frameworksPath + "/" + marker) {
                return true
            }
        }

        if let info = bundle.infoDictionary {
            let toDesktopKeys = ["ToDesktopAppId", "ToDesktopProductId", "ToDesktopUpdateURL"]
            for key in toDesktopKeys {
                if info[key] != nil {
                    return true
                }
            }
        }

        return false
    }

    private func isElectronApp(frameworksPath: String) -> Bool {
        let electronFramework = frameworksPath + "/Electron Framework.framework"
        return FileManager.default.fileExists(atPath: electronFramework)
    }

    private func isChromiumApp(frameworksPath: String) -> Bool {
        let fm = FileManager.default

        let chromiumMarkers = [
            "Chromium Framework.framework",
            "Google Chrome Framework.framework"
        ]

        for marker in chromiumMarkers {
            if fm.fileExists(atPath: frameworksPath + "/" + marker) {
                return true
            }
        }

        return false
    }
}

// MARK: - Batch

extension AppTypeDetector {

    /// Apps in /Applications that support data isolation.
    func scanApplicationsFolder() async -> [URL] {
        let applicationsPath = "/Applications"
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: applicationsPath),
            includingPropertiesForKeys: [.isApplicationKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.filter { url in
            url.pathExtension == "app" && detect(at: url).supportsDataIsolation
        }
    }

    func classifyApps(_ urls: [URL]) -> [URL: AppType] {
        var results: [URL: AppType] = [:]
        for url in urls {
            results[url] = detect(at: url)
        }
        return results
    }
}
