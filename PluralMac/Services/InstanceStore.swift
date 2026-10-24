//
//  InstanceStore.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import OSLog

/// instances.json in the base folder, cached in memory
actor InstanceStore {
    
    static let shared = InstanceStore()
    
    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "InstanceStore")
    private let fileManager = FileManager.default
    
    private var storeURL: URL {
        AppInstance.defaultBaseDirectory
            .appendingPathComponent("instances.json")
    }
    
    private var cachedInstances: [AppInstance]?
    
    private init() {}
    
    func loadInstances() async throws -> [AppInstance] {
        if let cached = cachedInstances {
            return cached
        }
        
        let baseDir = AppInstance.defaultBaseDirectory
        if !fileManager.fileExists(atPath: baseDir.path) {
            try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }
        
        guard fileManager.fileExists(atPath: storeURL.path) else {
            logger.info("No instances file found, returning empty array")
            cachedInstances = []
            return []
        }
        
        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let instances = try decoder.decode([AppInstance].self, from: data)
        cachedInstances = instances
        
        logger.info("Loaded \(instances.count) instances from storage")
        return instances
    }
    
    func saveInstances(_ instances: [AppInstance]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        let data = try encoder.encode(instances)
        
        let directory = storeURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        
        try data.write(to: storeURL, options: .atomic)
        cachedInstances = instances
        
        logger.info("Saved \(instances.count) instances to storage")
    }
    
    func addInstance(_ instance: AppInstance) async throws {
        var instances = try await loadInstances()
        instances.append(instance)
        try await saveInstances(instances)
        logger.info("Added instance: \(instance.name)")
    }
    
    func updateInstance(_ instance: AppInstance) async throws {
        var instances = try await loadInstances()
        
        guard let index = instances.firstIndex(where: { $0.id == instance.id }) else {
            throw StoreError.instanceNotFound(instance.id)
        }
        
        instances[index] = instance
        try await saveInstances(instances)
        logger.info("Updated instance: \(instance.name)")
    }
    
    func deleteInstance(id: UUID) async throws {
        var instances = try await loadInstances()
        
        guard let index = instances.firstIndex(where: { $0.id == id }) else {
            throw StoreError.instanceNotFound(id)
        }
        
        let removed = instances.remove(at: index)
        try await saveInstances(instances)
        logger.info("Deleted instance: \(removed.name)")
    }
    
    func getInstance(id: UUID) async throws -> AppInstance? {
        let instances = try await loadInstances()
        return instances.first { $0.id == id }
    }
    
    func clearCache() {
        cachedInstances = nil
        logger.debug("Cache cleared")
    }
}

enum StoreError: LocalizedError {
    case instanceNotFound(UUID)
    case saveFailed(Error)
    case loadFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .instanceNotFound(let id):
            return "Instance not found: \(id)"
        case .saveFailed(let error):
            return "Failed to save instances: \(error.localizedDescription)"
        case .loadFailed(let error):
            return "Failed to load instances: \(error.localizedDescription)"
        }
    }
}
