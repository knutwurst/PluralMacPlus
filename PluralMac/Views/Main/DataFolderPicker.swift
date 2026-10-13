//
//  DataFolderPicker.swift
//  PluralMac
//
//  Created by Knutwurst on 13.10.26.
//

import AppKit

/// Asks the user for a new parent folder for an instance's data.
enum DataFolderPicker {

    static func chooseParent(for instance: AppInstance) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = instance.dataPath.deletingLastPathComponent()
        panel.prompt = "Move Here"
        panel.message = "Choose where to move the data of \"\(instance.name)\". A folder named after the instance will be created there."

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
