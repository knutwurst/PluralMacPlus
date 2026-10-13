//
//  DataFolderMover.swift
//  PluralMac
//

import Foundation

/// Moves an instance's data folder to a new parent directory.
nonisolated struct DataFolderMover {

    enum MoveError: LocalizedError, Equatable {
        case instanceRunning
        case destinationExists(URL)
        case destinationInsideSource

        var errorDescription: String? {
            switch self {
            case .instanceRunning:
                return "Quit the instance before moving its data folder."
            case .destinationExists(let url):
                return "A folder already exists at \(url.path). Choose a different location."
            case .destinationInsideSource:
                return "The new location must not be inside the current data folder."
            }
        }
    }

    private let fileManager = FileManager.default

    /// Moves `source` to `<parent>/<folderName>` and returns the new location.
    /// If `source` does not exist yet (instance never launched), nothing is moved
    /// and only the new location is returned.
    func move(from source: URL, toParent parent: URL, folderName: String, instanceIsRunning: Bool) throws -> URL {
        guard !instanceIsRunning else {
            throw MoveError.instanceRunning
        }

        let destination = parent.appendingPathComponent(AppInstance.sanitizeFileName(folderName))

        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
            throw MoveError.destinationInsideSource
        }

        guard !fileManager.fileExists(atPath: destination.path) else {
            throw MoveError.destinationExists(destination)
        }

        guard fileManager.fileExists(atPath: source.path) else {
            return destination
        }

        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }
}
