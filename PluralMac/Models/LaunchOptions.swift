//
//  LaunchOptions.swift
//  PluralMac
//
//  Created by Knutwurst on 13.10.26.
//

import Foundation
import SwiftUI

/// Validation for custom environment variables and command-line arguments.
enum LaunchOptions {

    /// Variables PluralMac Plus sets itself for isolation; custom values would be overwritten
    static let reservedVariables: Set<String> = [
        "HOME", "CFFIXED_USER_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
    ]

    /// Why `name` can't be used as an environment variable, or nil if it can
    static func problem(withVariableName name: String) -> String? {
        guard !name.isEmpty else { return "Enter a variable name." }
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            return "Use letters, digits and underscores, not starting with a digit."
        }
        guard !reservedVariables.contains(name) else {
            return "\(name) is set by PluralMac Plus to isolate the instance."
        }
        return nil
    }

    /// Trimmed argument, or nil if it is blank
    static func normalizedArgument(_ argument: String) -> String? {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Manual ordering of instances in the sidebar.
enum InstanceOrdering {

    static func move(_ instances: [AppInstance], from source: IndexSet, to destination: Int) -> [AppInstance] {
        var result = instances
        result.move(fromOffsets: source, toOffset: destination)
        return result
    }
}
