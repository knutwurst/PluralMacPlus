//
//  PreferencesIsolation.swift
//  PluralMac
//
//  Created by Knutwurst on 14.10.26.
//

import Foundation
import Security

/// Separate UserDefaults per instance.
///
/// cfprefsd ignores HOME and CFFIXED_USER_HOME, so all instances of an app share one preferences
/// file. For apps without Hardened Runtime, the bundled libPMPPreferences.dylib is injected via
/// DYLD_INSERT_LIBRARIES and points `UserDefaults.standard` at a plist inside the instance folder.
nonisolated enum PreferencesIsolation {

    /// Environment variable the shim reads the preferences file path from
    static let fileEnvironmentKey = "PMP_PREFERENCES_FILE"

    static let shimFileName = "libPMPPreferences.dylib"

    /// Stable location of the shim, so launcher apps keep working when PluralMac Plus moves
    static var installedShimURL: URL {
        AppInstance.defaultBaseDirectory
            .appendingPathComponent("Support")
            .appendingPathComponent(shimFileName)
    }

    /// The shim inside the PluralMac Plus app bundle
    static var bundledShimURL: URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent(shimFileName)
    }

    /// Preferences file of an instance. It must not be named like the bundle ID: for such a path
    /// domain cfprefsd also mirrors AppKit apps' writes into the shared app domain.
    static func preferencesFile(dataPath: URL, bundleIdentifier: String) -> URL {
        dataPath
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(bundleIdentifier).pluralmacplus.plist")
    }

    /// File name used before 1.1.2 (named like the bundle ID, so writes leaked into the shared domain)
    static func legacyPreferencesFile(dataPath: URL, bundleIdentifier: String) -> URL {
        dataPath
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(bundleIdentifier).plist")
    }

    /// The app's shared preferences file in the real home folder
    static func sharedPreferencesFile(bundleIdentifier: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(bundleIdentifier).plist")
    }

    /// Copies the bundled shim to its stable location if it is missing or outdated
    static func installShim() throws {
        guard let bundled = bundledShimURL,
              let bundledData = try? Data(contentsOf: bundled) else { return }

        let target = installedShimURL
        if let installed = try? Data(contentsOf: target), installed == bundledData {
            return
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bundledData.write(to: target, options: .atomic)
    }

    /// Whether the app at `url` runs with Hardened Runtime
    static func usesHardenedRuntime(appAt url: URL) -> Bool {
        guard let flags = signingInformation(appAt: url)?[kSecCodeInfoFlags as String] as? UInt32 else {
            return false
        }
        return flags & SecCodeSignatureFlags.runtime.rawValue != 0
    }

    /// Whether macOS lets the shim be injected: either no Hardened Runtime, or the app opts in to
    /// DYLD environment variables and loading libraries signed by others
    static func allowsLibraryInjection(appAt url: URL) -> Bool {
        guard usesHardenedRuntime(appAt: url) else { return true }

        let entitlements = entitlements(appAt: url)
        return entitlements["com.apple.security.cs.allow-dyld-environment-variables"] as? Bool == true
            && entitlements["com.apple.security.cs.disable-library-validation"] as? Bool == true
    }

    /// Entitlements of the app's main executable
    static func entitlements(appAt url: URL) -> [String: Any] {
        signingInformation(appAt: url)?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    }

    private static func signingInformation(appAt url: URL) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &information) == errSecSuccess else {
            return nil
        }
        return information as? [String: Any]
    }
}

extension PreferencesIsolation {

    static func preferencesFile(for instance: AppInstance) -> URL {
        preferencesFile(dataPath: instance.dataPath, bundleIdentifier: instance.targetBundleIdentifier)
    }

    static func legacyPreferencesFile(for instance: AppInstance) -> URL {
        legacyPreferencesFile(dataPath: instance.dataPath, bundleIdentifier: instance.targetBundleIdentifier)
    }

    /// Gives the instance its starting preferences unless it already has its own: the file from an
    /// earlier version of PluralMac Plus if present, otherwise a copy of the shared preferences
    static func seedPreferences(for instance: AppInstance, from shared: URL? = nil) throws {
        let file = preferencesFile(for: instance)
        let legacy = legacyPreferencesFile(for: instance)
        let fileManager = FileManager.default
        let source = fileManager.fileExists(atPath: legacy.path)
            ? legacy
            : (shared ?? sharedPreferencesFile(bundleIdentifier: instance.targetBundleIdentifier))

        guard !fileManager.fileExists(atPath: file.path), fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: file)
    }
}
