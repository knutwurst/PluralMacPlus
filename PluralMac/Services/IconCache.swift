//
//  IconCache.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import AppKit
import OSLog

/// Memory + disk cache for app icons, keyed by bundle ID.
actor IconCache {

    static let shared = IconCache()

    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "IconCache")
    private let fileManager = FileManager.default

    private var memoryCache: [String: CachedIcon] = [:]

    private let maxMemoryCacheSize = 50

    private var cacheDirectory: URL {
        AppInstance.defaultBaseDirectory
            .appendingPathComponent("Cache")
            .appendingPathComponent("Icons")
    }

    private init() {
        Task {
            await ensureCacheDirectoryExists()
        }
    }

    // MARK: - Public

    func get(for appURL: URL) -> NSImage? {
        let key = cacheKey(for: appURL)

        if let cached = memoryCache[key], !cached.isExpired {
            logger.debug("Memory cache hit for: \(appURL.lastPathComponent)")
            return cached.image
        }

        if let diskImage = loadFromDisk(key: key) {
            memoryCache[key] = CachedIcon(image: diskImage)
            logger.debug("Disk cache hit for: \(appURL.lastPathComponent)")
            return diskImage
        }

        return nil
    }

    func set(_ image: NSImage, for appURL: URL) {
        let key = cacheKey(for: appURL)

        memoryCache[key] = CachedIcon(image: image)

        saveToDisk(image: image, key: key)

        evictIfNeeded()

        logger.debug("Cached icon for: \(appURL.lastPathComponent)")
    }

    func remove(for appURL: URL) {
        let key = cacheKey(for: appURL)

        memoryCache.removeValue(forKey: key)

        let diskPath = cacheDirectory.appendingPathComponent("\(key).png")
        try? fileManager.removeItem(at: diskPath)

        logger.debug("Removed cached icon for: \(appURL.lastPathComponent)")
    }

    func clearAll() {
        memoryCache.removeAll()

        if let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) {
            for file in contents {
                try? fileManager.removeItem(at: file)
            }
        }

        logger.info("Cleared all cached icons")
    }

    func diskCacheSize() -> Int64 {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        for file in contents {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }

        return totalSize
    }

    func cachedIconCount() -> Int {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }

        return contents.filter { $0.pathExtension == "png" }.count
    }

    // MARK: - Private

    private func ensureCacheDirectoryExists() {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
        }
    }

    private func cacheKey(for appURL: URL) -> String {
        if let bundle = Bundle(url: appURL),
           let bundleId = bundle.bundleIdentifier {
            return bundleId.replacingOccurrences(of: ".", with: "_")
        }

        // hashValue is seeded per launch, so for apps without a bundle ID
        // the disk cache only survives until PMP quits
        return String(appURL.path.hashValue)
    }

    private func loadFromDisk(key: String) -> NSImage? {
        let filePath = cacheDirectory.appendingPathComponent("\(key).png")

        guard fileManager.fileExists(atPath: filePath.path) else {
            return nil
        }

        return NSImage(contentsOf: filePath)
    }

    private func saveToDisk(image: NSImage, key: String) {
        // runs after this method returns, so it only helps the next write
        Task {
            await ensureCacheDirectoryExists()
        }

        let filePath = cacheDirectory.appendingPathComponent("\(key).png")

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }

        try? pngData.write(to: filePath)
    }

    /// Drops the oldest entries once there are more than maxMemoryCacheSize.
    private func evictIfNeeded() {
        guard memoryCache.count > maxMemoryCacheSize else { return }

        let sortedKeys = memoryCache.sorted { $0.value.timestamp < $1.value.timestamp }
        let keysToRemove = sortedKeys.prefix(memoryCache.count - maxMemoryCacheSize)

        for (key, _) in keysToRemove {
            memoryCache.removeValue(forKey: key)
        }

        logger.debug("Evicted \(keysToRemove.count) icons from memory cache")
    }
}

private struct CachedIcon {
    let image: NSImage
    let timestamp: Date

    static let expirationInterval: TimeInterval = 3600

    init(image: NSImage) {
        self.image = image
        self.timestamp = Date()
    }

    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > Self.expirationInterval
    }
}
