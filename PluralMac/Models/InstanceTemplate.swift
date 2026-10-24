//
//  InstanceTemplate.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation

/// Preset settings for a few well-known apps.
struct InstanceTemplate: Identifiable, Codable {
    
    let id: UUID
    let name: String
    let description: String
    let appType: AppType
    let suggestedName: String
    let environmentVariables: [String: String]
    let commandLineArguments: [String]
    let isolationMethod: DataIsolationMethod
    let iconSymbol: String
    
    init(
        id: UUID = UUID(),
        name: String,
        description: String,
        appType: AppType,
        suggestedName: String,
        environmentVariables: [String: String] = [:],
        commandLineArguments: [String] = [],
        isolationMethod: DataIsolationMethod = .homeRedirection,
        iconSymbol: String = "app.fill"
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.appType = appType
        self.suggestedName = suggestedName
        self.environmentVariables = environmentVariables
        self.commandLineArguments = commandLineArguments
        self.isolationMethod = isolationMethod
        self.iconSymbol = iconSymbol
    }
}

// MARK: - Built-in

extension InstanceTemplate {
    
    static let builtIn: [InstanceTemplate] = [
        .chromeWork,
        .chromePersonal,
        .chromeDev,
        .firefoxPrivate,
        .firefoxDev,
        
        .slackWork,
        .slackPersonal,
        .discordAlt,
        
        .vscodeProject,
        .cursorProject,
        
        .spotifyAlt
    ]
    
    static let chromeWork = InstanceTemplate(
        name: "Chrome - Work",
        description: "Chrome instance for work with separate profile",
        appType: .chromium,
        suggestedName: "Chrome Work",
        environmentVariables: [:],
        commandLineArguments: [],
        isolationMethod: .userDataDir,
        iconSymbol: "briefcase.fill"
    )
    
    static let chromePersonal = InstanceTemplate(
        name: "Chrome - Personal",
        description: "Chrome instance for personal browsing",
        appType: .chromium,
        suggestedName: "Chrome Personal",
        environmentVariables: [:],
        commandLineArguments: [],
        isolationMethod: .userDataDir,
        iconSymbol: "person.fill"
    )
    
    static let chromeDev = InstanceTemplate(
        name: "Chrome - Development",
        description: "Chrome for web development with DevTools flags",
        appType: .chromium,
        suggestedName: "Chrome Dev",
        environmentVariables: [:],
        commandLineArguments: [
            "--auto-open-devtools-for-tabs",
            "--disable-web-security",
            "--allow-running-insecure-content"
        ],
        isolationMethod: .userDataDir,
        iconSymbol: "hammer.fill"
    )
    
    static let firefoxPrivate = InstanceTemplate(
        name: "Firefox - Private",
        description: "Firefox with enhanced privacy settings",
        appType: .firefox,
        suggestedName: "Firefox Private",
        environmentVariables: [:],
        commandLineArguments: [],
        isolationMethod: .profileArgument,
        iconSymbol: "lock.shield.fill"
    )
    
    static let firefoxDev = InstanceTemplate(
        name: "Firefox - Developer",
        description: "Firefox for web development",
        appType: .firefox,
        suggestedName: "Firefox Dev",
        environmentVariables: [:],
        commandLineArguments: ["-devtools"],
        isolationMethod: .profileArgument,
        iconSymbol: "hammer.fill"
    )
    
    static let slackWork = InstanceTemplate(
        name: "Slack - Work",
        description: "Slack for primary work workspace",
        appType: .electron,
        suggestedName: "Slack Work",
        environmentVariables: [:],
        commandLineArguments: [],
        isolationMethod: .homeRedirection,
        iconSymbol: "briefcase.fill"
    )
    
    static let slackPersonal = InstanceTemplate(
        name: "Slack - Personal",
        description: "Slack for personal or secondary workspaces",
        appType: .electron,
        suggestedName: "Slack Personal",
        environmentVariables: [:],
        commandLineArguments: [],
        isolationMethod: .homeRedirection,
        iconSymbol: "person.fill"
    )
    
    // Discord ignores HOME and --user-data-dir, so "alt account" is more of a wish (see AppInstance)
    static let discordAlt = InstanceTemplate(
        name: "Discord - Alt Account",
        description: "Discord for alternative account",
        appType: .electron,
        suggestedName: "Discord Alt",
        environmentVariables: [:],
        commandLineArguments: [],
        isolationMethod: .homeRedirection,
        iconSymbol: "person.2.fill"
    )
    
    static let vscodeProject = InstanceTemplate(
        name: "VS Code - Project",
        description: "VS Code with isolated settings and extensions",
        appType: .electron,
        suggestedName: "VS Code Project",
        environmentVariables: [:],
        commandLineArguments: [],
        isolationMethod: .homeRedirection,
        iconSymbol: "folder.fill"
    )
    
    static let cursorProject = InstanceTemplate(
        name: "Cursor - Project",
        description: "Cursor IDE with isolated settings",
        appType: .electron,
        suggestedName: "Cursor Project",
        environmentVariables: [:],
        commandLineArguments: [],
        isolationMethod: .homeRedirection,
        iconSymbol: "folder.fill"
    )
    
    static let spotifyAlt = InstanceTemplate(
        name: "Spotify - Alt Account",
        description: "Spotify for secondary account",
        appType: .electron,
        suggestedName: "Spotify Alt",
        environmentVariables: [:],
        commandLineArguments: [],
        isolationMethod: .homeRedirection,
        iconSymbol: "music.note"
    )
}

// MARK: - Matching

extension InstanceTemplate {
    
    /// templates for the app's type, narrowed down by bundle ID when one fits
    static func templates(for application: Application) -> [InstanceTemplate] {
        let appType = application.appType
        let bundleId = application.bundleIdentifier.lowercased()
        
        var matching = builtIn.filter { $0.appType == appType }
        
        if bundleId.contains("chrome") {
            matching = matching.filter { $0.name.lowercased().contains("chrome") }
        } else if bundleId.contains("firefox") || bundleId.contains("waterfox") {
            matching = matching.filter { $0.name.lowercased().contains("firefox") }
        } else if bundleId.contains("slack") {
            matching = matching.filter { $0.name.lowercased().contains("slack") }
        } else if bundleId.contains("discord") {
            matching = matching.filter { $0.name.lowercased().contains("discord") }
        } else if bundleId.contains("code") || bundleId.contains("vscode") {
            matching = matching.filter { $0.name.lowercased().contains("vs code") }
        } else if bundleId.contains("cursor") {
            matching = matching.filter { $0.name.lowercased().contains("cursor") }
        } else if bundleId.contains("spotify") {
            matching = matching.filter { $0.name.lowercased().contains("spotify") }
        }
        
        // nothing specific, so everything of that type
        if matching.isEmpty {
            matching = builtIn.filter { $0.appType == appType }
        }
        
        return matching
    }
    
    static func generic(for application: Application) -> InstanceTemplate {
        InstanceTemplate(
            name: "Custom Instance",
            description: "Create a custom instance with default settings",
            appType: application.appType,
            suggestedName: "\(application.name) Instance",
            environmentVariables: [:],
            commandLineArguments: [],
            isolationMethod: application.appType.isolationMethod,
            iconSymbol: "app.fill"
        )
    }
}
