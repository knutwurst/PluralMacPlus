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

@MainActor
@Observable
final class InstanceViewModel {
    
    var instances: [AppInstance] = []
    
    var selectedInstance: AppInstance?
    
    var searchText: String = ""
    
    var isLoading: Bool = false
    
    var errorMessage: String?
    
    var showError: Bool = false
    
    var instancesMovingData: Set<UUID> = []
    
    var instancesBuildingCopy: Set<UUID> = []
    
    // keyed by icon source + hue
    @ObservationIgnored private var displayIconCache: [String: NSImage] = [:]
    
    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "InstanceViewModel")
    private let store = InstanceStore.shared
    private let directLauncher = DirectLauncher.shared
    
    var filteredInstances: [AppInstance] {
        guard !searchText.isEmpty else { return instances }
        
        let lowercasedSearch = searchText.lowercased()
        return instances.filter { instance in
            instance.name.lowercased().contains(lowercasedSearch) ||
            instance.targetBundleIdentifier.lowercased().contains(lowercasedSearch)
        }
    }
    
    var hasInstances: Bool {
        !instances.isEmpty
    }
    
    var instanceCount: Int {
        instances.count
    }
    
    init() {
        // private copies can only be rebuilt while their instance is down
        NotificationCenter.default.addObserver(forName: .instanceTerminated, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshOutdatedPrivateCopies()
            }
        }
        
        // pick up instances started by launcher apps while PluralMac Plus is open
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
    
    // MARK: - Loading
    
    func loadInstances() async {
        // the test host runs PMP itself, keep its hands off the real instances
        guard !AppEnvironment.isRunningTests else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            instances = try await store.loadInstances()
            logger.info("Loaded \(self.instances.count) instances")
        } catch {
            handleError(error, context: "loading instances")
        }
        
        // launchers and instances load the preferences shim from a fixed location
        do {
            try PreferencesIsolation.installShim()
            for instance in instances where instance.separatePreferences == true {
                try PreferencesIsolation.seedPreferences(for: instance)
            }
        } catch {
            logger.error("Preparing separate preferences failed: \(error.localizedDescription)")
        }
        
        // instances may still be running from before PluralMac Plus was (re)opened
        await discoverRunningInstances()
        
        await refreshOutdatedLaunchers()
        await refreshOutdatedPrivateCopies()
    }
    
    /// Fresh start script for copies from older versions, with stale settings or a broken signature.
    /// Running ones are skipped and get it when they quit.
    func refreshOutdatedPrivateCopies() async {
        guard !AppEnvironment.isRunningTests else { return }
        for instance in instances where PrivateCopyBuilder.needsRefresh(instance)
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
    
    /// Rebuilds launchers whose script went stale, e.g. after an app update.
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
    
    /// Adopts already running processes that belong to an instance.
    func discoverRunningInstances() async {
        let processes = RunningInstanceMatcher.runningProcesses(for: instances)
        let matches = RunningInstanceMatcher.match(instances: instances, processes: processes)
        
        for (instanceId, pid) in matches {
            await directLauncher.adopt(instanceId, pid: pid)
        }
    }
    
    func refreshInstances() async {
        await store.clearCache()
        await loadInstances()
    }
    
    // MARK: - Create
    
    /// dataPath nil = Data Directory setting, launcherFolder nil = no launcher.
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
        
        try await store.addInstance(instance)
        
        instances.append(instance)
        
        if let launcherFolder {
            await createLauncher(for: instance, in: launcherFolder)
        }
        
        logger.info("Successfully created instance: \(name)")
        return instances.first { $0.id == instance.id } ?? instance
    }
    
    // MARK: - Update
    
    func updateInstance(_ instance: AppInstance) async throws {
        logger.info("Updating instance: \(instance.name)")
        
        // launcher app and private copy follow name, data folder and arguments
        var instance = instance
        if PrivateCopyBuilder.needsRefresh(instance) {
            try await refreshPrivateCopyIdentityIfIdle(&instance)
        }
        if instance.launcherPath != nil {
            instance.launcherPath = await refreshedLauncher(for: instance)
        }
        
        try await persist(instance)
        logger.info("Successfully updated instance: \(instance.name)")
    }
    
    /// Store, local list and selection only. Leaves launcher and copy alone.
    private func persist(_ instance: AppInstance) async throws {
        try await store.updateInstance(instance)
        
        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[index] = instance
        }
        
        if selectedInstance?.id == instance.id {
            selectedInstance = instance
        }
    }
    
    /// Blank names are ignored, errors go to the alert.
    func renameInstance(_ instance: AppInstance, to newName: String) async {
        guard let name = AppInstance.validatedName(newName), name != instance.name else { return }
        
        var updated = instance
        updated.rename(to: name)
        
        do {
            try await updateInstance(updated)
        } catch {
            handleError(error, context: "renaming instance")
        }
    }
    
    // MARK: - Launcher App
    
    /// Reports errors via the alert instead of throwing.
    func createLauncher(for instance: AppInstance, in folder: URL) async {
        do {
            var updated = instances.first { $0.id == instance.id } ?? instance
            let previous = updated.launcherPath
            let launcher = try await installLauncher(for: updated, in: folder)
            
            // a launcher in a new place replaces the old one
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
    
    /// Trashes the launcher and forgets it.
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
    
    func revealLauncherInFinder(_ instance: AppInstance) {
        if let launcher = instance.launcherPath {
            LaunchServicesHelper.revealInFinder(launcher)
        }
    }
    
    /// Checks the disk, not just launcherPath.
    func hasLauncher(_ instance: AppInstance) -> Bool {
        guard let launcher = instance.launcherPath else { return false }
        return LauncherBuilder.isLauncher(at: launcher, for: instance.id)
    }
    
    private func installLauncher(for instance: AppInstance, in folder: URL) async throws -> URL {
        // the launcher starts the app without PluralMac Plus, so the data folder has to exist now
        if instance.redirectsHome {
            try await directLauncher.prepareDataDirectory(dataPath: instance.dataPath)
        }
        
        let builder = LauncherBuilder()
        let launcher = try builder.build(for: instance, in: folder)
        builder.writeIcon(launcherIcon(for: instance), into: launcher)
        builder.sign(launcher)
        return launcher
    }
    
    /// Returns the new location (the name may have changed), nil if the launcher is gone.
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
    
    /// Includes the instance hue.
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
    
    /// Custom or app icon, tinted and cached.
    func displayIcon(for instance: AppInstance) -> NSImage {
        let key = "\(instance.customIconPath?.path ?? instance.targetAppPath.path)|\(instance.launcherIconHue.map { String($0) } ?? "-")"
        if let cached = displayIconCache[key] {
            return cached
        }
        
        let base: NSImage
        if let custom = instance.customIconPath, let image = NSImage(contentsOf: custom) {
            base = image
        } else {
            base = NSWorkspace.shared.icon(forFile: instance.targetAppPath.path)
        }
        // list and header show it at 64pt max
        let small = base.copy() as! NSImage
        small.size = NSSize(width: 128, height: 128)
        
        let icon = instance.launcherIconHue.map { LauncherBuilder.tinted(small, hueDegrees: $0) } ?? small
        displayIconCache[key] = icon
        return icon
    }
    
    /// Rebuilds an existing launcher with the new color.
    func setLauncherIconHue(_ instance: AppInstance, hue: Double?) async {
        var updated = instance
        updated.launcherIconHue = hue
        updated.touch()
        
        do {
            try await updateInstance(updated)
        } catch {
            handleError(error, context: "changing icon color")
        }
    }
    
    // MARK: - Private Copy
    
    /// Also rebuilds an existing copy.
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
        let starter = PrivateCopyBuilder.usesStarter(instance)
        
        do {
            // copying and signing a big app takes a while, keep it off the main actor
            let copy = try await Task.detached {
                try PrivateCopyBuilder().build(instanceID: id, name: name, original: original, iconPNG: icon,
                                               startScript: startScript, starter: starter)
            }.value
            
            var updated = instances.first { $0.id == instance.id } ?? instance
            var built = copy
            built.iconHue = instance.launcherIconHue
            updated.privateCopy = built
            updated.touch()
            try await updateInstance(updated)
            logger.info("Built private copy of \(instance.name) at \(copy.path.path)")
        } catch {
            handleError(error, context: "creating private copy")
        }
    }
    
    /// Back to the original app, the copy goes to the Trash.
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
    
    /// The original got updated since the copy was made.
    func isPrivateCopyOutdated(_ instance: AppInstance) -> Bool {
        PrivateCopyBuilder.isOutdated(instance)
    }
    
    private func trashPrivateCopy(of instance: AppInstance) {
        let folder = PrivateCopyBuilder.defaultClonesDirectory.appendingPathComponent(instance.id.uuidString)
        if FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
    }
    
    /// Pushes name, icon and start script into the copy. Skipped while it runs, launchInstance catches up.
    private func refreshPrivateCopyIdentityIfIdle(_ instance: inout AppInstance) async throws {
        guard let current = instance.privateCopy, !(await directLauncher.isRunning(instance.id)) else { return }
        
        let id = instance.id, name = instance.name, original = instance.targetAppPath
        let icon = PrivateCopyBuilder.pngData(launcherIcon(for: instance))
        let startScript = PrivateCopyBuilder.startScript(for: instance)
        var refreshed = try await Task.detached {
            try PrivateCopyBuilder().updateIdentity(of: current, instanceID: id, name: name, original: original, iconPNG: icon, startScript: startScript)
        }.value
        refreshed.iconHue = instance.launcherIconHue
        instance.privateCopy = refreshed
    }
    
    // MARK: - Data Folder
    
    /// Moves it into `parent` as a folder named after the instance.
    func moveDataFolder(_ instance: AppInstance, toParent parent: URL) async {
        logger.info("Moving data folder of \(instance.name) to \(parent.path)")
        
        instancesMovingData.insert(instance.id)
        defer { instancesMovingData.remove(instance.id) }
        
        // argument-isolated apps keep their data in the profile folder, so that's what moves
        let source = instance.isolationRoot
        let folderName = instance.name
        let isRunning = await directLauncher.isRunning(instance.id)
        
        do {
            // across volumes this is a full copy, so not on the main actor
            let destination = try await Task.detached {
                try DataFolderMover().move(from: source, toParent: parent, folderName: folderName, instanceIsRunning: isRunning)
            }.value
            
            var updated = instance
            Self.repoint(&updated, from: source, to: destination)
            updated.touch()
            try await updateInstance(updated)
            
            logger.info("Moved data folder of \(instance.name) to \(destination.path)")
        } catch {
            handleError(error, context: "moving data folder")
        }
    }
    
    /// What "Delete Shortcut & Data" trashes. Never a profile folder the user picked.
    nonisolated static func dataFolderToDelete(for instance: AppInstance) -> URL? {
        if let profile = instance.profilePath,
           profile.standardizedFileURL.path == instance.dataPath.standardizedFileURL.path {
            return nil
        }
        return instance.dataPath
    }
    
    /// Repoints dataPath/profilePath that were at `source`.
    nonisolated static func repoint(_ instance: inout AppInstance, from source: URL, to destination: URL) {
        let moved = source.standardizedFileURL.path
        if instance.dataPath.standardizedFileURL.path == moved {
            instance.dataPath = destination
        }
        if instance.profilePath?.standardizedFileURL.path == moved {
            instance.profilePath = destination
        }
    }
    
    /// Point the app at an existing profile folder (nil = data folder). Applies at the next start.
    func setProfileFolder(_ instance: AppInstance, to folder: URL?) async {
        var updated = instance
        updated.profilePath = folder
        updated.touch()
        await save(updated, context: "changing profile folder")
    }
    
    // MARK: - Hardware ID
    
    /// Own hardware UUID on/off. Applies at the next start.
    func setSeparateHardwareID(_ instance: AppInstance, enabled: Bool) async {
        var updated = instance
        updated.hardwareIDOverride = enabled ? HardwareIdentity.separateID(for: instance.id) : nil
        updated.touch()
        await save(updated, context: "changing device ID")
    }
    
    /// New random UUID, applies at the next start.
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
    
    /// Preferences live in the instance folder. First time on, it gets a copy of the shared ones
    /// so nothing is lost. Applies at the next start.
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
    
    func moveInstances(from source: IndexSet, to destination: Int) async {
        instances = InstanceOrdering.move(instances, from: source, to: destination)
        do {
            try await store.saveInstances(instances)
        } catch {
            handleError(error, context: "saving instance order")
        }
    }
    
    // MARK: - Delete
    
    func deleteInstance(_ instance: AppInstance, deleteData: Bool = false) async throws {
        logger.info("Deleting instance: \(instance.name), deleteData: \(deleteData)")
        
        if await directLauncher.isRunning(instance.id) {
            _ = await directLauncher.terminate(instance.id)
        }
        
        // Trash, not rm, so a wrong click can be undone
        if deleteData, let folder = Self.dataFolderToDelete(for: instance) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: folder.path) {
                try fileManager.trashItem(at: folder, resultingItemURL: nil)
                logger.debug("Moved data to the Trash: \(folder.path)")
            }
        }
        
        trashPrivateCopy(of: instance)
        
        // only if it's really a PMP launcher, never whatever else sits at that path
        if let launcher = instance.launcherPath, LauncherBuilder.isLauncher(at: launcher, for: instance.id) {
            try? FileManager.default.trashItem(at: launcher, resultingItemURL: nil)
        }
        
        try await store.deleteInstance(id: instance.id)
        
        instances.removeAll { $0.id == instance.id }
        
        if selectedInstance?.id == instance.id {
            selectedInstance = nil
        }
        
        logger.info("Successfully deleted instance: \(instance.name)")
    }
    
    func deleteInstances(_ instances: [AppInstance], deleteData: Bool = false) async throws {
        for instance in instances {
            try await deleteInstance(instance, deleteData: deleteData)
        }
    }
    
    // MARK: - Launch
    
    /// Brings it to the front instead if it already runs.
    func launchInstance(_ instance: AppInstance) async throws {
        if await directLauncher.isRunning(instance.id) {
            await bringToFront(instance)
            return
        }
        
        logger.info("Launching instance directly: \(instance.name)")
        
        // a rename or icon change while it ran gets applied to the copy now
        var instance = instance
        if PrivateCopyBuilder.needsRefresh(instance) {
            try await refreshPrivateCopyIdentityIfIdle(&instance)
            try await updateInstance(instance)
        }
        
        let process = try await directLauncher.launch(instance)
        
        var updated = instance
        updated.recordLaunch()
        try await store.updateInstance(updated)
        
        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[index] = updated
        }
        
        logger.info("Successfully launched instance: \(instance.name) (PID: \(process.processIdentifier))")
    }
    
    /// Also restores a minimized window.
    func bringToFront(_ instance: AppInstance) async {
        guard let pid = await directLauncher.runningPID(instance.id),
              let app = NSRunningApplication(processIdentifier: pid) else {
            return
        }
        logger.info("Bringing instance to front: \(instance.name)")
        InstanceActivator.bringToFront(app)
    }
    
    func isInstanceRunning(_ instance: AppInstance) -> Bool {
        // careful: blocks the main actor while the Task wants it back. Use checkIsRunning.
        var isRunning = false
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            isRunning = await directLauncher.isRunning(instance.id)
            semaphore.signal()
        }
        semaphore.wait()
        return isRunning
    }
    
    func terminateInstance(_ instance: AppInstance) async -> Bool {
        logger.info("Terminating instance: \(instance.name)")
        return await directLauncher.terminate(instance.id)
    }
    
    func forceTerminateInstance(_ instance: AppInstance) async -> Bool {
        logger.info("Force terminating instance: \(instance.name)")
        return await directLauncher.forceTerminate(instance.id)
    }
    
    func checkIsRunning(_ instance: AppInstance) async -> Bool {
        await directLauncher.isRunning(instance.id)
    }
    
    // MARK: - Finder
    
    /// The target app, not the instance data.
    func revealInFinder(_ instance: AppInstance) {
        LaunchServicesHelper.revealInFinder(instance.targetAppPath)
    }
    
    func revealDataInFinder(_ instance: AppInstance) {
        LaunchServicesHelper.revealInFinder(instance.isolationRoot)
    }
    
    // MARK: - Duplicate
    
    func duplicateInstance(_ instance: AppInstance, newName: String) async throws -> AppInstance {
        logger.info("Duplicating instance: \(instance.name) as \(newName)")
        
        let application = try Application(from: instance.targetAppPath)
        
        var newInstance = AppInstance(name: newName, application: application)
        newInstance.environmentVariables = instance.environmentVariables
        newInstance.commandLineArguments = instance.commandLineArguments
        newInstance.customIconPath = instance.customIconPath
        newInstance.isolationMethodOverride = instance.isolationMethodOverride
        newInstance.eraseDataOnQuit = instance.eraseDataOnQuit
        newInstance.showMenuBarIcon = instance.showMenuBarIcon
        
        try await store.addInstance(newInstance)
        
        instances.append(newInstance)
        
        return newInstance
    }
    
    // MARK: - Import / Export
    
    func exportInstances(_ instancesToExport: [AppInstance], to url: URL) async throws {
        logger.info("Exporting \(instancesToExport.count) instances")
        try await ImportExportManager.shared.exportToFile(instancesToExport, destination: url)
        logger.info("Successfully exported instances to \(url.path)")
    }
    
    func exportAllInstances(to url: URL) async throws {
        try await exportInstances(instances, to: url)
    }
    
    func importInstances(from url: URL) async throws -> [ImportValidationResult] {
        logger.info("Importing instances from \(url.path)")
        
        let configs = try await ImportExportManager.shared.importFromFile(url)
        let validationResults = await ImportExportManager.shared.validateImport(configs)
        
        return validationResults
    }
    
    func createFromImport(_ configs: [ImportedInstanceConfig]) async throws {
        for config in configs {
            do {
                let instance = try config.createInstance()
                
                try await store.addInstance(instance)
                
                instances.append(instance)
                
                logger.info("Imported instance: \(instance.name)")
            } catch {
                logger.error("Failed to import \(config.name): \(error.localizedDescription)")
                throw error
            }
        }
    }
    
    private func handleError(_ error: Error, context: String) {
        logger.error("Error \(context): \(error.localizedDescription)")
        errorMessage = error.localizedDescription
        showError = true
    }
    
    func clearError() {
        errorMessage = nil
        showError = false
    }
}

// MARK: - Selection

extension InstanceViewModel {
    
    func select(_ instance: AppInstance?) {
        selectedInstance = instance
    }
    
    func isSelected(_ instance: AppInstance) -> Bool {
        selectedInstance?.id == instance.id
    }
    
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
