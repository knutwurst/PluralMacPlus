//
//  PreferencesIsolation.swift
//  PluralMac
//
//  Created by Knutwurst on 14.10.26.
//

import Foundation
import Security

/// Separate UserDefaults per instance. cfprefsd ignores HOME and CFFIXED_USER_HOME, so every instance
/// would share one plist. libPMPPreferences.dylib goes in via DYLD_INSERT_LIBRARIES (no Hardened
/// Runtime only) and points `UserDefaults.standard` at a plist in the instance folder.
nonisolated enum PreferencesIsolation {

    /// the shim reads the plist path from here
    static let fileEnvironmentKey = "PMP_PREFERENCES_FILE"

    static let shimFileName = "libPMPPreferences.dylib"

    /// fixed location, so launchers keep working when PluralMac Plus itself gets moved
    static var installedShimURL: URL {
        AppInstance.defaultBaseDirectory
            .appendingPathComponent("Support")
            .appendingPathComponent(shimFileName)
    }

    static var bundledShimURL: URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent(shimFileName)
    }

    /// Must not be named like the bundle ID. For such a path domain cfprefsd mirrors AppKit apps'
    /// writes into the shared app domain as well.
    static func preferencesFile(dataPath: URL, bundleIdentifier: String) -> URL {
        dataPath
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(bundleIdentifier).pluralmacplus.plist")
    }

    /// pre-1.1.2 name, the one that leaked writes into the shared domain
    static func legacyPreferencesFile(dataPath: URL, bundleIdentifier: String) -> URL {
        dataPath
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(bundleIdentifier).plist")
    }

    /// the app's normal plist in the real home folder
    static func sharedPreferencesFile(bundleIdentifier: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(bundleIdentifier).plist")
    }

    /// copies the bundled shim over if it is missing or outdated
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

    static func usesHardenedRuntime(appAt url: URL) -> Bool {
        guard let flags = signingInformation(appAt: url)?[kSecCodeInfoFlags as String] as? UInt32 else {
            return false
        }
        return flags & SecCodeSignatureFlags.runtime.rawValue != 0
    }

    /// Hardened Runtime blocks DYLD_INSERT_LIBRARIES unless the app allows DYLD env vars and
    /// libraries signed by someone else
    static func allowsLibraryInjection(appAt url: URL) -> Bool {
        guard usesHardenedRuntime(appAt: url) else { return true }

        let entitlements = entitlements(appAt: url)
        return entitlements["com.apple.security.cs.allow-dyld-environment-variables"] as? Bool == true
            && entitlements["com.apple.security.cs.disable-library-validation"] as? Bool == true
    }

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

    /// Starting preferences unless the instance has its own already: the pre-1.1.2 file if there is
    /// one, otherwise a copy of the shared plist
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
