//
//  IconExtractor.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import AppKit
import OSLog

actor IconExtractor {

    static let shared = IconExtractor()

    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "IconExtractor")
    private let fileManager = FileManager.default
    private let cache = IconCache.shared

    private init() {}

    // MARK: - Extraction

    func extractIcon(from appURL: URL, size: Int = 512) async throws -> NSImage {
        logger.debug("Extracting icon from: \(appURL.lastPathComponent)")

        if let cached = await cache.get(for: appURL) {
            logger.debug("Using cached icon for: \(appURL.lastPathComponent)")
            return cached
        }

        if let bundleIcon = try? extractFromBundle(appURL: appURL) {
            await cache.set(bundleIcon, for: appURL)
            return bundleIcon
        }

        let icon = await extractUsingWorkspace(appURL: appURL, size: size)
        await cache.set(icon, for: appURL)

        return icon
    }

    private func extractFromBundle(appURL: URL) throws -> NSImage? {
        guard let bundle = Bundle(url: appURL) else {
            return nil
        }

        if let iconFileName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            var iconName = iconFileName
            if !iconName.hasSuffix(".icns") {
                iconName += ".icns"
            }

            let iconPath = appURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent(iconName)

            if fileManager.fileExists(atPath: iconPath.path),
               let icon = NSImage(contentsOf: iconPath) {
                logger.debug("Extracted icon from CFBundleIconFile: \(iconName)")
                return icon
            }
        }

        // Asset catalog icon: can't read it from here, the caller falls back to NSWorkspace
        if let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String {
            logger.debug("App uses Asset Catalog icon: \(iconName)")
        }

        return nil
    }

    /// Also handles asset catalog icons, which extractFromBundle can't.
    @MainActor
    private func extractUsingWorkspace(appURL: URL, size: Int) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)

        let resized = resizeImage(icon, to: NSSize(width: size, height: size))

        logger.debug("Extracted icon using NSWorkspace")
        return resized
    }

    // MARK: - Conversion

    func saveAsPNG(image: NSImage, to destination: URL, size: Int? = nil) throws {
        var imageToSave = image

        if let size = size {
            imageToSave = resizeImage(image, to: NSSize(width: size, height: size))
        }

        guard let tiffData = imageToSave.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw IconError.conversionFailed("Could not create PNG")
        }

        try pngData.write(to: destination)
        logger.debug("Saved PNG to: \(destination.path)")
    }

    // MARK: - Image Manipulation

    nonisolated func resizeImage(_ image: NSImage, to size: NSSize) -> NSImage {
        let newImage = NSImage(size: size)

        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )

        newImage.unlockFocus()

        return newImage
    }

    // MARK: - Custom Icons

}


// MARK: - Errors

enum IconError: LocalizedError {
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .conversionFailed(let message):
            return "Icon conversion failed: \(message)"
        }
    }
}
