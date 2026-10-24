//
//  Application.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import AppKit

struct Application: Identifiable, Codable, Hashable, Sendable {
    
    let id: String
    let bundleIdentifier: String
    let name: String
    let path: URL
    let executablePath: URL
    let appType: AppType
    let version: String?
    
    /// App Store receipt found, see checkIfSandboxed
    let isSandboxed: Bool
    let iconFileName: String?
    
    init(from url: URL) throws {
        guard let bundle = Bundle(url: url) else {
            throw ApplicationError.invalidBundle(url)
        }
        
        guard let bundleId = bundle.bundleIdentifier else {
            throw ApplicationError.missingBundleIdentifier(url)
        }
        
        guard let executableURL = bundle.executableURL else {
            throw ApplicationError.missingExecutable(url)
        }
        
        if bundleId.hasPrefix("com.apple.") {
            throw ApplicationError.systemAppNotSupported(bundleId)
        }
        
        self.id = bundleId
        self.bundleIdentifier = bundleId
        self.path = url
        self.executablePath = executableURL
        
        self.name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        
        self.version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        
        self.iconFileName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String
        
        self.isSandboxed = Self.checkIfSandboxed(bundle: bundle)
        
        self.appType = Self.detectAppType(
            bundleIdentifier: bundleId,
            bundle: bundle,
            isSandboxed: self.isSandboxed
        )
    }
    
    // MARK: - Detection
    
    /// Only looks for an App Store receipt. The honest answer is in the entitlements, which would
    /// mean parsing the code signature. Good enough so far.
    private static func checkIfSandboxed(bundle: Bundle) -> Bool {
        let bundlePath = bundle.bundlePath
        
        let receiptPath = bundle.appStoreReceiptURL
        if let receipt = receiptPath, FileManager.default.fileExists(atPath: receipt.path) {
            return true
        }
        
        return false
    }
    
    private static func detectAppType(
        bundleIdentifier: String,
        bundle: Bundle,
        isSandboxed: Bool
    ) -> AppType {
        if isSandboxed {
            return .sandboxed
        }
        
        let chromiumIdentifiers = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.microsoft.edgemac",
            "com.microsoft.edgemac.Dev",
            "com.brave.Browser",
            "com.vivaldi.Vivaldi",
            "company.thebrowser.Browser", // Arc
            "org.chromium.Chromium",
            "com.operasoftware.Opera",
            "com.nicothin.nickel" // Nickel Browser
        ]
        if chromiumIdentifiers.contains(where: { bundleIdentifier.hasPrefix($0) }) {
            return .chromium
        }
        
        let firefoxIdentifiers = [
            "org.mozilla.firefox",
            "org.mozilla.nightly",
            "org.waterfox.waterfox",
            "io.gitlab.librewolf-community"
        ]
        if firefoxIdentifiers.contains(where: { bundleIdentifier.hasPrefix($0) }) {
            return .firefox
        }
        
        // ToDesktop apps ship Electron too, so they go first
        if Self.isToDesktopApp(bundle: bundle) {
            return .toDesktop
        }
        
        if Self.isElectronApp(bundle: bundle) {
            return .electron
        }
        
        return .generic
    }
    
    private static func isToDesktopApp(bundle: Bundle) -> Bool {
        let frameworksPath = bundle.bundlePath + "/Contents/Frameworks"
        let toDesktopMarkers = [
            "ToDesktop Runtime Helper.app",
            "ToDesktopRuntimeHelper"
        ]
        
        for marker in toDesktopMarkers {
            if FileManager.default.fileExists(atPath: frameworksPath + "/" + marker) {
                return true
            }
        }
        
        if let infoPlist = bundle.infoDictionary {
            if infoPlist["ToDesktopAppId"] != nil || infoPlist["ToDesktopProductId"] != nil {
                return true
            }
        }
        
        return false
    }
    
    private static func isElectronApp(bundle: Bundle) -> Bool {
        let frameworksPath = bundle.bundlePath + "/Contents/Frameworks"
        let electronFramework = frameworksPath + "/Electron Framework.framework"
        
        return FileManager.default.fileExists(atPath: electronFramework)
    }
    
    func validate() throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ApplicationError.appNotFound(path)
        }
        
        guard FileManager.default.isExecutableFile(atPath: executablePath.path) else {
            throw ApplicationError.executableNotAccessible(executablePath)
        }
        
        guard appType.supportsDataIsolation else {
            throw ApplicationError.unsupportedAppType(appType)
        }
    }
}

// MARK: - Errors

enum ApplicationError: LocalizedError {
    case invalidBundle(URL)
    case missingBundleIdentifier(URL)
    case missingExecutable(URL)
    case systemAppNotSupported(String)
    case appNotFound(URL)
    case executableNotAccessible(URL)
    case unsupportedAppType(AppType)
    
    var errorDescription: String? {
        switch self {
        case .invalidBundle(let url):
            return "Invalid application bundle at: \(url.path)"
        case .missingBundleIdentifier(let url):
            return "Application has no bundle identifier: \(url.path)"
        case .missingExecutable(let url):
            return "Application has no executable: \(url.path)"
        case .systemAppNotSupported(let bundleId):
            return "Apple system apps are not supported: \(bundleId)"
        case .appNotFound(let url):
            return "Application not found at: \(url.path)"
        case .executableNotAccessible(let url):
            return "Cannot access executable: \(url.path)"
        case .unsupportedAppType(let type):
            return "App type '\(type.displayName)' does not support data isolation"
        }
    }
}

// MARK: - Convenience

extension Application {
    @MainActor
    var icon: NSImage? {
        NSWorkspace.shared.icon(forFile: path.path)
    }
    
    var isBrowser: Bool {
        appType == .chromium || appType == .firefox
    }
    
    func dataIsolationArguments(dataPath: URL) -> [String] {
        switch appType {
        case .chromium:
            return ["--user-data-dir=\(dataPath.path)"]
        case .firefox:
            return ["-profile", dataPath.path]
        default:
            return []
        }
    }
}
