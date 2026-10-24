//
//  AppType.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import SwiftUI

/// Decides which isolation strategy an app gets.
enum AppType: String, Codable, CaseIterable, Sendable {
    /// Chrome, Edge, Brave, Vivaldi, Arc ... (`--user-data-dir`)
    case chromium
    
    /// Firefox, Waterfox, LibreWolf ... (`-profile`)
    case firefox
    
    case electron
    
    /// Cursor, Linear and other ToDesktop wrappers. Behave like Electron.
    case toDesktop
    
    /// anything else that isn't sandboxed, isolated via HOME
    case generic
    
    /// App Store sandbox, the container wins. Not supported.
    case sandboxed
    
    /// com.apple.*, hands off
    case system
    
    var supportsDataIsolation: Bool {
        switch self {
        case .chromium, .firefox, .electron, .toDesktop, .generic:
            return true
        case .sandboxed, .system:
            return false
        }
    }
    
    var displayName: String {
        switch self {
        case .chromium: return "Chromium-based Browser"
        case .firefox: return "Firefox-based Browser"
        case .electron: return "Electron App"
        case .toDesktop: return "ToDesktop App"
        case .generic: return "Generic App"
        case .sandboxed: return "Sandboxed App (Not Supported)"
        case .system: return "System App (Not Supported)"
        }
    }
    
    var isolationMethod: DataIsolationMethod {
        switch self {
        case .chromium:
            return .userDataDir
        case .firefox:
            return .profileArgument
        case .electron, .toDesktop:
            // Most Electron/CEF apps support --user-data-dir
            return .userDataDir
        case .generic:
            return .homeRedirection
        case .sandboxed, .system:
            return .none
        }
    }
    
    var compatibilityLevel: CompatibilityLevel {
        switch self {
        case .chromium, .firefox:
            return .full
        case .electron, .toDesktop:
            return .full
        case .generic:
            return .partial
        case .sandboxed, .system:
            return .unsupported
        }
    }
}

enum DataIsolationMethod: String, Codable, Sendable {
    case userDataDir
    case profileArgument
    case homeRedirection
    case none
}

enum CompatibilityLevel: String, Codable, Sendable {
    case full
    
    /// own home folder (HOME/CFFIXED_USER_HOME). Fine for apps that stick to the usual Library folders.
    case partial
    
    case unsupported
    
    var symbolName: String {
        switch self {
        case .full: return "checkmark.circle.fill"
        case .partial: return "house.circle.fill"
        case .unsupported: return "xmark.circle.fill"
        }
    }
    
    var colorName: String {
        switch self {
        case .full: return "green"
        case .partial: return "blue"
        case .unsupported: return "red"
        }
    }
}

extension CompatibilityLevel {
    var color: Color {
        switch self {
        case .full: return .green
        case .partial: return .blue
        case .unsupported: return .red
        }
    }
}
