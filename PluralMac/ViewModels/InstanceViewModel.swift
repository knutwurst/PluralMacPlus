//
//  InstanceViewModel.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import AppKit
import SwiftUI
import OSLog

/// ViewModel for managing the list of app instances.
/// Handles loading, creating, updating, deleting, and launching instances.
@MainActor
@Observable
final class InstanceViewModel {
    
    // MARK: - Properties
    
    /// All app instances
    var instances: [AppInstance] = []
    
    /// Currently selected instance (for detail view)
    var selectedInstance: AppInstance?
    
    /// Search/filter text
    var searchText: String = ""
    
    /// Loading state
    var isLoading: Bool = false
    
    /// Error message to display
    var errorMessage: String?
    
    /// Whether to show error alert
    var showError: Bool = false
    
    /// Instances whose data folder is currently being moved
    var instancesMovingData: Set<UUID> = []
    
    /// Instances whose private app copy is being built
    var instancesBuildingCopy: Set<UUID> = []
    
    // MARK: - Private Properties
    
    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "InstanceViewModel")
    private let store = InstanceStore.shared
    private let directLauncher = DirectLauncher.shared
    
    // MARK: - Computed Properties
    
    /// Filtered instances based on search text
    var filteredInstances: [AppInstance] {
        guard !searchText.isEmpty else { return instances }
        
        let lowercasedSearch = searchText.lowercased()
        return instances.filter { instance in
            instance.name.lowercased().contains(lowercasedSearch) ||
            instance.targetBundleIdentifier.lowercased().contains(lowercasedSearch)
        }
    }
    
    /// Whether there are any instances
    var hasInstances: Bool {
        !instances.isEmpty
    }
    
    /// Number of instances
    var instanceCount: Int {
        instances.count
    }
    
    // MARK: - Initialization
    
    init() {
        // A private copy can only be updated while its instance is not running
        NotificationCenter.default.addObserver(forName: .instanceTerminated, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshOutdatedPrivateCopies()
            }
        }
        
        // Pick up instances started by launcher apps while PluralMac Plus is open
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.discoverRunningInstances()
            }
        }
    }
    
    // MARK: - Data Loading
    
    /// Load instances from storage
    func loadInstances() async {
        // Never touch the user's real instances from the unit test host
        guard !AppEnvironment.isRunningTests else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            instances = try await store.loadInstances()
            logger.info("Loaded \(self.instances.count) instances")
        } catch {
            handleError(error, context: "loading instances")
        }
        
        // Launchers and instances load the preferences shim from a stable location
        do {
            try PreferencesIsolation.installShim()
            for instance in instances where instance.separatePreferences == true {
                try PreferencesIsolation.seedPreferences(for: instance)
            }
        } catch {
            logger.error("Preparing separate preferences failed: \(error.localizedDescription)")
        }
        
        // Instances may still be running from before PluralMac Plus was (re)opened
        await discoverRunningInstances()
        
        await refreshOutdatedLaunchers()
        await refreshOutdatedPrivateCopies()
    }
    
    /// Give private copies made by an earlier version (or with stale settings or a broken signature)
    /// a current start script; running instances are skipped and handled when they quit
    func refreshOutdatedPrivateCopies() async {
        guard !AppEnvironment.isRunningTests else { return }
        for instance in instances where PrivateCopyBuilder.isStartScriptOutdated(instance)
            || instance.privateCopy.map({ !PrivateCopyBuilder.isSignatureValid($0.path) }) == true {
            guard !(await directLauncher.isRunning(instance.id)) else { continue }
            var updated = instance
            do {
                try await refreshPrivateCopyIdentityIfIdle(&updated)
                try await persist(updated)
                logger.info("Updated private copy of \(instance.name)")
            } catch {
                logger.error("Updating private copy of \(instance.name) failed: \(error.localizedDescription)")
            }
        }
    }
    
    /// Rebuild launcher apps whose script no longer matches the instance (e.g. after an app update)
    private func refreshOutdatedLaunchers() async {
        let builder = LauncherBuilder()
        for instance in instances {
            guard let launcher = instance.launcherPath,
                  LauncherBuilder.isLauncher(at: launcher, for: instance.id),
                  !builder.isUpToDate(launcher, for: instance) else {
                continue
            }
            logger.info("Updating outdated launcher of \(instance.name)")
            try? await updateInstance(instance)
        }
    }
    
    /// Find running processes that belong to instances and track them
    func discoverRunningInstances() async {
        let processes = RunningInstanceMatcher.runningProcesses(for: instances)
        let matches = RunningInstanceMatcher.match(instances: instances, processes: processes)
        
        for (instanceId, pid) in matches {
            await directLauncher.adopt(instanceId, pid: pid)
        }
    }
    
    /// Refresh instances from storage
    func refreshInstances() async {
        await store.clearCache()
        await loadInstances()
    }
    
    // MARK: - Instance Creation
    
    /// Create a new instance from an application
    /// - Parameters:
    ///   - name: Display name for the instance
    ///   - application: Target application
    ///   - environmentVariables: Custom environment variables
    ///   - arguments: Custom command-line arguments
    ///   - customIconPath: Optional custom icon
    ///   - dataPath: Optional data folder (nil = Data Directory setting)
    ///   - launcherFolder: Folder for a launcher app (nil = no launcher)
    ///   - launcherIconHue: Hue rotation for the launcher icon (nil = original colors)
    /// - Returns: The created instance
    @discardableResult
    func createInstance(
        name: String,
        application: Application,
        environmentVariables: [String: String] = [:],
        arguments: [String] = [],
        customIconPath: URL? = nil,
        dataPath: URL? = nil,
        launcherFolder: URL? = nil,
        launcherIconHue: Double? = nil,
        separateHardwareID: Bool = false,
        separatePreferences: Bool = false
    ) async throws -> AppInstance {
        logger.info("Creating instance: \(name) for \(application.name)")
        
        if let dataPath, let owner = AppInstance.instance(usingDataPath: dataPath, in: instances) {
            throw InstanceActionError.dataPathInUse(owner.name)
        }
        
        // Create the instance model
        var instance = AppInstance(name: name, application: application, dataPath: dataPath)
        instance.environmentVariables = environmentVariables
        instance.commandLineArguments = arguments
        instance.customIconPath = customIconPath
        instance.launcherIconHue = launcherIconHue
        if separateHardwareID {
            instance.hardwareIDOverride = HardwareIdentity.separateID(for: instance.id)
        }
        if separatePreferences && PreferencesIsolation.allowsLibraryInjection(appAt: application.path) {
            instance.separatePreferences = true
        }
        
        // No bundle creation needed - we launch directly!
        // Just save to storage
        try await store.addInstance(instance)
        
        // Update local list
        instances.append(instance)
        
        if let launcherFolder {
            await createLauncher(for: instance, in: launcherFolder)
        }
        
        logger.info("Successfully created instance: \(name)")
        return instances.first { $0.id == instance.id } ?? instance
    }
    
    // MARK: - Instance Updates
    
    /// Update an existing instance
    func updateInstance(_ instance: AppInstance) async throws {
        logger.info("Updating instance: \(instance.name)")
        
        // Keep an existing launcher app and private copy in sync (name, data folder, arguments)
        var instance = instance
        if PrivateCopyBuilder.isStartScriptOutdated(instance) {
            try await refreshPrivateCopyIdentityIfIdle(&instance)
        }
        if instance.launcherPath != nil {
            instance.launcherPath = await refreshedLauncher(for: instance)
        }
        
        try await persist(instance)
        logger.info("Successfully updated instance: \(instance.name)")
    }
    
    /// Save an instance and update the local list and selection
    private func persist(_ instance: AppInstance) async throws {
        try await store.updateInstance(instance)
        
        // Update local list
        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[index] = instance
        }
        
        // Update selection if needed
        if selectedInstance?.id == instance.id {
            selectedInstance = instance
        }
    }
    
    /// Rename an instance. Blank names are ignored; errors are shown in the error alert.
    func renameInstance(_ instance: AppInstance, to newName: String) async {
        guard let name = AppInstance.validatedName(newName), name != instance.name else { return }
        
        var updated = instance
        updated.rename(to: name)
        
        do {
            try await refreshPrivateCopyIdentityIfIdle(&updated)
            try await updateInstance(updated)
        } catch {
            handleError(error, context: "renaming instance")
        }
    }
    
    // MARK: - Launcher App
    
    /// Create a launcher app for the instance in `folder`. Errors are shown in the error alert.
    func createLauncher(for instance: AppInstance, in folder: URL) async {
        do {
            var updated = instances.first { $0.id == instance.id } ?? instance
            let previous = updated.launcherPath
            let launcher = try await installLauncher(for: updated, in: folder)
            
            // Creating it elsewhere replaces the old one
            if let previous, previous.standardizedFileURL != launcher.standardizedFileURL,
               LauncherBuilder.isLauncher(at: previous, for: instance.id) {
                try? FileManager.default.trashItem(at: previous, resultingItemURL: nil)
            }
            
            updated.launcherPath = launcher
            try await persist(updated)
            logger.info("Created launcher for \(instance.name) at \(launcher.path)")
        } catch {
            handleError(error, context: "creating launcher app")
        }
    }
    
    /// Move the launcher app to the Trash and forget it. Errors are shown in the error alert.
    func removeLauncher(for instance: AppInstance) async {
        guard let launcher = instance.launcherPath else { return }
        
        do {
            try LauncherBuilder.remove(launcher, for: instance.id)
            var updated = instances.first { $0.id == instance.id } ?? instance
            updated.launcherPath = nil
            try await persist(updated)
            logger.info("Removed launcher of \(instance.name)")
        } catch {
            handleError(error, context: "removing launcher app")
        }
    }
    
    /// Reveal the launcher app in Finder
    func revealLauncherInFinder(_ instance: AppInstance) {
        if let launcher = instance.launcherPath {
            LaunchServicesHelper.revealInFinder(launcher)
        }
    }
    
    /// Whether the instance has a launcher app on disk
    func hasLauncher(_ instance: AppInstance) -> Bool {
        guard let launcher = instance.launcherPath else { return false }
        return LauncherBuilder.isLauncher(at: launcher, for: instance.id)
    }
    
    private func installLauncher(for instance: AppInstance, in folder: URL) async throws -> URL {
        // The launcher starts the app without PluralMac Plus, so prepare the data folder now
        try await directLauncher.prepareDataDirectory(dataPath: instance.dataPath)
        
        let builder = LauncherBuilder()
        let launcher = try builder.build(for: instance, in: folder)
        builder.writeIcon(launcherIcon(for: instance), into: launcher)
        builder.sign(launcher)
        return launcher
    }
    
    /// Rebuild an existing launcher; returns its (possibly renamed) location, or nil if it no longer exists
    private func refreshedLauncher(for instance: AppInstance) async -> URL? {
        guard let old = instance.launcherPath, LauncherBuilder.isLauncher(at: old, for: instance.id) else {
            return nil
        }
        
        do {
            let new = try await installLauncher(for: instance, in: old.deletingLastPathComponent())
            if new.standardizedFileURL != old.standardizedFileURL {
                try? FileManager.default.trashItem(at: old, resultingItemURL: nil)
            }
            return new
        } catch {
            handleError(error, context: "updating launcher app")
            return old
        }
    }
    
    /// Icon for the launcher app, including the hue chosen for the instance
    func launcherIcon(for instance: AppInstance) -> NSImage {
        let base: NSImage
        if let custom = instance.customIconPath, let image = NSImage(contentsOf: custom) {
            base = image
        } else {
            base = NSWorkspace.shared.icon(forFile: instance.targetAppPath.path)
            base.size = NSSize(width: 512, height: 512)
        }
        
        guard let hue = instance.launcherIconHue else { return base }
        return LauncherBuilder.tinted(base, hueDegrees: hue)
    }
    
    /// Change the launcher icon color; an existing launcher is rebuilt. Errors are shown in the error alert.
    func setLauncherIconHue(_ instance: AppInstance, hue: Double?) async {
        var updated = instance
        updated.launcherIconHue = hue
        updated.touch()
        
        do {
            try await refreshPrivateCopyIdentityIfIdle(&updated)
            try await updateInstance(updated)
        } catch {
            handleError(error, context: "changing launcher icon")
        }
    }
    
    // MARK: - Private App Copy
    
    /// Build (or rebuild) a private copy of the app for the instance. Errors are shown in the error alert.
    func createPrivateCopy(for instance: AppInstance) async {
        guard !(await directLauncher.isRunning(instance.id)) else {
            handleError(PrivateCopyError.instanceRunning, context: "creating private copy")
            return
        }
        
        instancesBuildingCopy.insert(instance.id)
        defer { instancesBuildingCopy.remove(instance.id) }
        
        let id = instance.id, name = instance.name, original = instance.targetAppPath
        let icon = PrivateCopyBuilder.pngData(launcherIcon(for: instance))
        let startScript = PrivateCopyBuilder.startScript(for: instance)
        
        do {
            // Copying and signing a large app takes a while; keep the UI responsive
            let copy = try await Task.detached {
                try PrivateCopyBuilder().build(instanceID: id, name: name, original: original, iconPNG: icon, startScript: startScript)
            }.value
            
            var updated = instances.first { $0.id == instance.id } ?? instance
            updated.privateCopy = copy
            updated.touch()
            try await updateInstance(updated)
            logger.info("Built private copy of \(instance.name) at \(copy.path.path)")
        } catch {
            handleError(error, context: "creating private copy")
        }
    }
    
    /// Go back to running the original app; the copy moves to the Trash
    func removePrivateCopy(from instance: AppInstance) async {
        guard !(await directLauncher.isRunning(instance.id)) else {
            handleError(PrivateCopyError.instanceRunning, context: "removing private copy")
            return
        }
        
        trashPrivateCopy(of: instance)
        var updated = instance
        updated.privateCopy = nil
        updated.touch()
        await save(updated, context: "removing private copy")
    }
    
    /// Whether the original app was updated after the copy was made
    func isPrivateCopyOutdated(_ instance: AppInstance) -> Bool {
        PrivateCopyBuilder.isOutdated(instance)
    }
    
    private func trashPrivateCopy(of instance: AppInstance) {
        let folder = PrivateCopyBuilder.defaultClonesDirectory.appendingPathComponent(instance.id.uuidString)
        if FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
    }
    
    /// Apply name, icon and start script to the copy unless the instance is running (then it
    /// happens before the next launch)
    private func refreshPrivateCopyIdentityIfIdle(_ instance: inout AppInstance) async throws {
        guard let current = instance.privateCopy, !(await directLauncher.isRunning(instance.id)) else { return }
        
        let id = instance.id, name = instance.name, original = instance.targetAppPath
        let icon = PrivateCopyBuilder.pngData(launcherIcon(for: instance))
        let startScript = PrivateCopyBuilder.startScript(for: instance)
        instance.privateCopy = try await Task.detached {
            try PrivateCopyBuilder().updateIdentity(of: current, instanceID: id, name: name, original: original, iconPNG: icon, startScript: startScript)
        }.value
    }
    
    // MARK: - Data Folder
    
    /// Move the instance's data folder into `parent`. Errors are shown in the error alert.
    func moveDataFolder(_ instance: AppInstance, toParent parent: URL) async {
        logger.info("Moving data folder of \(instance.name) to \(parent.path)")
        
        instancesMovingData.insert(instance.id)
        defer { instancesMovingData.remove(instance.id) }
        
        let source = instance.dataPath
        let folderName = instance.name
        let isRunning = await directLauncher.isRunning(instance.id)
        
        do {
            // Run off the main actor: moving across volumes copies the whole folder
            let destination = try await Task.detached {
                try DataFolderMover().move(from: source, toParent: parent, folderName: folderName, instanceIsRunning: isRunning)
            }.value
            
            var updated = instance
            updated.dataPath = destination
            updated.touch()
            try await updateInstance(updated)
            
            logger.info("Moved data folder of \(instance.name) to \(destination.path)")
        } catch {
            handleError(error, context: "moving data folder")
        }
    }
    
    // MARK: - Hardware ID
    
    /// Report a separate hardware UUID to the app (or the real one again). Applies at the next start.
    func setSeparateHardwareID(_ instance: AppInstance, enabled: Bool) async {
        var updated = instance
        updated.hardwareIDOverride = enabled ? HardwareIdentity.separateID(for: instance.id) : nil
        updated.touch()
        await save(updated, context: "changing device ID")
    }
    
    /// Give the instance a new random hardware UUID. Applies at the next start.
    func regenerateHardwareID(_ instance: AppInstance) async {
        var updated = instance
        updated.hardwareIDOverride = UUID()
        updated.touch()
        await save(updated, context: "changing device ID")
    }
    
    private func save(_ instance: AppInstance, context: String) async {
        do {
            try await updateInstance(instance)
        } catch {
            handleError(error, context: context)
        }
    }
    
    // MARK: - Preferences
    
    /// Keep the app's preferences in the instance folder. On first use the instance gets a copy of
    /// the shared preferences, so nothing is lost. Applies at the next start.
    func setSeparatePreferences(_ instance: AppInstance, enabled: Bool) async {
        var updated = instance
        updated.separatePreferences = enabled ? true : nil
        updated.touch()
        
        do {
            if enabled {
                try PreferencesIsolation.installShim()
                try PreferencesIsolation.seedPreferences(for: updated)
            }
            try await updateInstance(updated)
        } catch {
            handleError(error, context: "changing preferences isolation")
        }
    }
    
    // MARK: - Ordering
    
    /// Reorder instances in the sidebar and save the new order
    func moveInstances(from source: IndexSet, to destination: Int) async {
        instances = InstanceOrdering.move(instances, from: source, to: destination)
        do {
            try await store.saveInstances(instances)
        } catch {
            handleError(error, context: "saving instance order")
        }
    }
    
    // MARK: - Instance Deletion
    
    /// Delete an instance
    /// - Parameters:
    ///   - instance: The instance to delete
    ///   - deleteData: Whether to also delete isolated data
    func deleteInstance(_ instance: AppInstance, deleteData: Bool = false) async throws {
        logger.info("Deleting instance: \(instance.name), deleteData: \(deleteData)")
        
        // Terminate if running
        if await directLauncher.isRunning(instance.id) {
            _ = await directLauncher.terminate(instance.id)
        }
        
        // Delete data directory if requested
        if deleteData {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: instance.dataPath.path) {
                try fileManager.removeItem(at: instance.dataPath)
                logger.debug("Deleted data at: \(instance.dataPath.path)")
            }
        }
        
        // Private app copy goes to the Trash as well
        trashPrivateCopy(of: instance)
        
        // Move our launcher app to the Trash (recoverable)
        if let launcher = instance.launcherPath, LauncherBuilder.isLauncher(at: launcher, for: instance.id) {
            try? FileManager.default.trashItem(at: launcher, resultingItemURL: nil)
        }
        
        // Remove from storage
        try await store.deleteInstance(id: instance.id)
        
        // Update local list
        instances.removeAll { $0.id == instance.id }
        
        // Clear selection if deleted
        if selectedInstance?.id == instance.id {
            selectedInstance = nil
        }
        
        logger.info("Successfully deleted instance: \(instance.name)")
    }
    
    /// Delete multiple instances
    func deleteInstances(_ instances: [AppInstance], deleteData: Bool = false) async throws {
        for instance in instances {
            try await deleteInstance(instance, deleteData: deleteData)
        }
    }
    
    // MARK: - Instance Launching
    
    /// Launch an instance, or bring it to the front if it is already running
    func launchInstance(_ instance: AppInstance) async throws {
        if await directLauncher.isRunning(instance.id) {
            await bringToFront(instance)
            return
        }
        
        logger.info("Launching instance directly: \(instance.name)")
        
        // A rename or icon change while the instance ran is applied to the copy now
        var instance = instance
        if let copy = instance.privateCopy,
           (NSDictionary(contentsOf: copy.path.appendingPathComponent("Contents/Info.plist"))?["CFBundleName"] as? String) != instance.name
            || PrivateCopyBuilder.isStartScriptOutdated(instance) {
            try await refreshPrivateCopyIdentityIfIdle(&instance)
            try await updateInstance(instance)
        }
        
        // Launch the app directly with modified environment
        let process = try await directLauncher.launch(instance)
        
        // Update last launched timestamp
        var updated = instance
        updated.recordLaunch()
        try await store.updateInstance(updated)
        
        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[index] = updated
        }
        
        logger.info("Successfully launched instance: \(instance.name) (PID: \(process.processIdentifier))")
    }
    
    /// Bring a running instance to the front and restore a minimized window
    func bringToFront(_ instance: AppInstance) async {
        guard let pid = await directLauncher.runningPID(instance.id),
              let app = NSRunningApplication(processIdentifier: pid) else {
            return
        }
        logger.info("Bringing instance to front: \(instance.name)")
        InstanceActivator.bringToFront(app)
    }
    
    /// Check if an instance is currently running
    func isInstanceRunning(_ instance: AppInstance) -> Bool {
        // Check synchronously - we need to make this async-safe
        var isRunning = false
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            isRunning = await directLauncher.isRunning(instance.id)
            semaphore.signal()
        }
        semaphore.wait()
        return isRunning
    }
    
    /// Terminate a running instance
    func terminateInstance(_ instance: AppInstance) async -> Bool {
        logger.info("Terminating instance: \(instance.name)")
        return await directLauncher.terminate(instance.id)
    }
    
    /// Force terminate a running instance
    func forceTerminateInstance(_ instance: AppInstance) async -> Bool {
        logger.info("Force terminating instance: \(instance.name)")
        return await directLauncher.forceTerminate(instance.id)
    }
    
    /// Check running status asynchronously
    func checkIsRunning(_ instance: AppInstance) async -> Bool {
        await directLauncher.isRunning(instance.id)
    }
    
    // MARK: - Finder Integration
    
    /// Reveal target app in Finder
    func revealInFinder(_ instance: AppInstance) {
        LaunchServicesHelper.revealInFinder(instance.targetAppPath)
    }
    
    /// Reveal instance data directory in Finder
    func revealDataInFinder(_ instance: AppInstance) {
        LaunchServicesHelper.revealInFinder(instance.dataPath)
    }
    
    // MARK: - Duplicate
    
    /// Duplicate an instance with a new name
    func duplicateInstance(_ instance: AppInstance, newName: String) async throws -> AppInstance {
        logger.info("Duplicating instance: \(instance.name) as \(newName)")
        
        // Load the original application
        let application = try Application(from: instance.targetAppPath)
        
        // Create new instance with same settings
        var newInstance = AppInstance(name: newName, application: application)
        newInstance.environmentVariables = instance.environmentVariables
        newInstance.commandLineArguments = instance.commandLineArguments
        newInstance.customIconPath = instance.customIconPath
        newInstance.isolationMethodOverride = instance.isolationMethodOverride
        newInstance.eraseDataOnQuit = instance.eraseDataOnQuit
        newInstance.showMenuBarIcon = instance.showMenuBarIcon
        
        // No bundle needed - just save to storage
        try await store.addInstance(newInstance)
        
        // Update local list
        instances.append(newInstance)
        
        return newInstance
    }
    
    // MARK: - Import/Export
    
    /// Export selected instances to a file
    func exportInstances(_ instancesToExport: [AppInstance], to url: URL) async throws {
        logger.info("Exporting \(instancesToExport.count) instances")
        try await ImportExportManager.shared.exportToFile(instancesToExport, destination: url)
        logger.info("Successfully exported instances to \(url.path)")
    }
    
    /// Export all instances to a file
    func exportAllInstances(to url: URL) async throws {
        try await exportInstances(instances, to: url)
    }
    
    /// Import instances from a file
    /// - Parameter url: The file to import from
    /// - Returns: Array of validation results
    func importInstances(from url: URL) async throws -> [ImportValidationResult] {
        logger.info("Importing instances from \(url.path)")
        
        let configs = try await ImportExportManager.shared.importFromFile(url)
        let validationResults = await ImportExportManager.shared.validateImport(configs)
        
        return validationResults
    }
    
    /// Create instances from validated import configs
    func createFromImport(_ configs: [ImportedInstanceConfig]) async throws {
        for config in configs {
            do {
                let instance = try config.createInstance()
                
                // No bundle needed - just save to storage
                try await store.addInstance(instance)
                
                // Update local list
                instances.append(instance)
                
                logger.info("Imported instance: \(instance.name)")
            } catch {
                logger.error("Failed to import \(config.name): \(error.localizedDescription)")
                throw error
            }
        }
    }
    
    // MARK: - Error Handling
    
    private func handleError(_ error: Error, context: String) {
        logger.error("Error \(context): \(error.localizedDescription)")
        errorMessage = error.localizedDescription
        showError = true
    }
    
    /// Clear the current error
    func clearError() {
        errorMessage = nil
        showError = false
    }
}

// MARK: - Selection Helpers

extension InstanceViewModel {
    
    /// Select an instance
    func select(_ instance: AppInstance?) {
        selectedInstance = instance
    }
    
    /// Check if an instance is selected
    func isSelected(_ instance: AppInstance) -> Bool {
        selectedInstance?.id == instance.id
    }
    
    /// Select the first instance if none selected
    func selectFirstIfNeeded() {
        if selectedInstance == nil, let first = filteredInstances.first {
            selectedInstance = first
        }
    }
}

// MARK: - Errors

enum PrivateCopyError: LocalizedError {
    case instanceRunning
    
    var errorDescription: String? {
        "Quit the instance first. Its app copy can't be replaced while it runs."
    }
}

enum InstanceActionError: LocalizedError {
    case dataPathInUse(String)
    
    var errorDescription: String? {
        switch self {
        case .dataPathInUse(let name):
            return "This data folder is already used by \"\(name)\". Choose a different folder."
        }
    }
}
