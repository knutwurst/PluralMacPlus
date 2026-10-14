//
//  InstanceDetailView.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Detail view showing full information about a selected instance.
struct InstanceDetailView: View {
    
    // MARK: - Properties
    
    let instance: AppInstance
    @Bindable var viewModel: InstanceViewModel
    
    @State private var appIcon: NSImage?
    @State private var isRenaming = false
    @State private var newName: String = ""
    @State private var showDeleteConfirmation = false
    @State private var deleteData = false
    @State private var showExportSheet = false
    @State private var showDuplicateSheet = false
    @State private var duplicateName: String = ""
    @State private var launcherIconHue: Double?
    @State private var showLaunchOptionsEditor = false
    @State private var confirmNewDeviceID = false
    @State private var confirmPrivateCopy = false
    @State private var editedEnvironment: [String: String] = [:]
    @State private var editedArguments: [String] = []
    
    @ObservedObject private var runningManager = RunningInstancesManager.shared
    
    /// Check if this instance is running
    private var isRunning: Bool {
        runningManager.isRunning(instance.id)
    }
    
    /// Whether the data folder is currently being moved
    private var isMovingData: Bool {
        viewModel.instancesMovingData.contains(instance.id)
    }
    
    // MARK: - Body
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                headerSection
                
                Divider()
                
                // Info sections
                targetAppSection
                
                Divider()
                
                dataIsolationSection
                
                Divider()
                
                launcherSection
                
                Divider()
                
                launchOptionsSection
                
                Divider()
                
                timestampsSection
                
                Spacer()
            }
            .padding(24)
        }
        .frame(minWidth: 400)
        .toolbar {
            toolbarContent
        }
        .task {
            await loadIcon()
        }
        .alert("Rename Instance", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                Task {
                    await viewModel.renameInstance(instance, to: newName)
                }
            }
        }
        .confirmationDialog(
            "Delete Instance",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Shortcut Only", role: .destructive) {
                Task {
                    try? await viewModel.deleteInstance(instance, deleteData: false)
                }
            }
            Button("Delete Shortcut & Data", role: .destructive) {
                Task {
                    try? await viewModel.deleteInstance(instance, deleteData: true)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you want to delete just the shortcut, or also delete all isolated data?")
        }
        .alert("Duplicate Instance", isPresented: $showDuplicateSheet) {
            TextField("New Name", text: $duplicateName)
            Button("Cancel", role: .cancel) {}
            Button("Duplicate") {
                Task {
                    try? await viewModel.duplicateInstance(instance, newName: duplicateName)
                }
            }
        } message: {
            Text("Enter a name for the duplicated instance:")
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        HStack(spacing: 16) {
            // Icon
            Group {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            
            // Name and type
            VStack(alignment: .leading, spacing: 4) {
                Text(instance.name)
                    .font(.title)
                    .fontWeight(.semibold)
                
                HStack(spacing: 6) {
                    Image(systemName: instance.targetAppType.compatibilityLevel.symbolName)
                        .foregroundStyle(instance.targetAppType.compatibilityLevel.color)
                    
                    Text(instance.targetAppType.displayName)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            
            Spacer()
            
            // Running status indicator
            if isRunning {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("Running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.green.opacity(0.15))
                .clipShape(Capsule())
            }
            
            // Launch or Stop button
            if isRunning {
                HStack(spacing: 8) {
                    Button {
                        Task {
                            await viewModel.bringToFront(instance)
                        }
                    } label: {
                        Label("Show", systemImage: "macwindow")
                    }
                    .controlSize(.large)
                    .help("Bring to front and restore minimized windows")
                    
                    // Stop button
                    Button(role: .destructive) {
                        Task {
                            _ = await viewModel.terminateInstance(instance)
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                }
            } else {
                Button {
                    Task {
                        try? await viewModel.launchInstance(instance)
                    }
                } label: {
                    Label("Launch", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
    
    // MARK: - Target App Section
    
    private var targetAppSection: some View {
        DetailSection(title: "Target Application") {
            DetailRow(label: "Application", value: targetAppName)
            DetailRow(label: "Bundle ID", value: instance.targetBundleIdentifier)
            DetailRow(label: "Path", value: instance.targetAppPath.path)
                .contextMenu {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(instance.targetAppPath.path, forType: .string)
                    }
                    Button("Show in Finder") {
                        LaunchServicesHelper.revealInFinder(instance.targetAppPath)
                    }
                }
        }
    }
    
    private var targetAppName: String {
        instance.targetAppPath.deletingPathExtension().lastPathComponent
    }
    
    // MARK: - Data Isolation Section
    
    private var dataIsolationSection: some View {
        DetailSection(title: "Data Isolation") {
            DetailRow(label: "Method", value: instance.effectiveIsolationMethod.rawValue.capitalized)
            preferencesRows
            privateCopyRows
            deviceIDRows
            DetailRow(label: "Data Path", value: instance.dataPath.path)
                .contextMenu {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(instance.dataPath.path, forType: .string)
                    }
                    Button("Show in Finder") {
                        viewModel.revealDataInFinder(instance)
                    }
                    Button("Move Data Folder...") {
                        moveDataFolder()
                    }
                    .disabled(isRunning || isMovingData)
                }
            HStack(spacing: 8) {
                Button("Move Data Folder...") {
                    moveDataFolder()
                }
                .disabled(isRunning || isMovingData)
                
                if isMovingData {
                    ProgressView()
                        .controlSize(.small)
                    Text("Moving data...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isRunning {
                    Text("Quit the instance to move its data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            DetailRow(label: "Shortcut Path", value: instance.shortcutPath.path)
                .contextMenu {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(instance.shortcutPath.path, forType: .string)
                    }
                    Button("Show in Finder") {
                        viewModel.revealInFinder(instance)
                    }
                }
        }
    }
    
    // MARK: - Device ID
    
    /// Whether the target app blocks injected libraries (Hardened Runtime without opt-in)
    private var targetBlocksInjection: Bool {
        !PreferencesIsolation.allowsLibraryInjection(appAt: instance.launchAppPath)
    }
    
    private var isBuildingCopy: Bool {
        viewModel.instancesBuildingCopy.contains(instance.id)
    }
    
    @ViewBuilder
    private var privateCopyRows: some View {
        if let copy = instance.privateCopy {
            DetailRow(label: "App", value: "Private copy, made from version \(copy.originalVersion)")
                .contextMenu {
                    Button("Show in Finder") { LaunchServicesHelper.revealInFinder(copy.path) }
                }
            if viewModel.isPrivateCopyOutdated(instance) {
                Label("The original app was updated to \(PrivateCopyBuilder.versionString(of: instance.targetAppPath)). Recreate the copy to use the new version.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button("Recreate Copy") {
                    Task { await viewModel.createPrivateCopy(for: instance) }
                }
                Button("Use Original App") {
                    Task { await viewModel.removePrivateCopy(from: instance) }
                }
                if isBuildingCopy {
                    ProgressView().controlSize(.small)
                }
            }
            .disabled(isRunning || isBuildingCopy)
        } else if targetBlocksInjection {
            HStack(spacing: 8) {
                Button("Use a Private Copy...") {
                    confirmPrivateCopy = true
                }
                .disabled(isRunning || isBuildingCopy)
                if isBuildingCopy {
                    ProgressView().controlSize(.small)
                    Text("Copying and signing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .confirmationDialog("Run this instance from a private copy?", isPresented: $confirmPrivateCopy, titleVisibility: .visible) {
                Button("Create Private Copy") {
                    Task { await viewModel.createPrivateCopy(for: instance) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("PluralMac Plus copies the app, names it \"\(instance.name)\" and signs the copy without Hardened Runtime, so preferences and device ID can be separated. The copy shows the instance name in the Dock.\n\nUpdates of the original don't reach the copy; recreate it after updating. macOS may ask again for camera or microphone access. Apps that use iCloud, push notifications or keychain groups may not start from a copy.")
            }
        }
    }
    
    @ViewBuilder
    private var preferencesRows: some View {
        Toggle("Separate preferences", isOn: Binding(
            get: { instance.separatePreferences == true },
            set: { enabled in
                Task { await viewModel.setSeparatePreferences(instance, enabled: enabled) }
            }
        ))
        .disabled(targetBlocksInjection && instance.separatePreferences != true)
        
        Text(targetBlocksInjection
             ? "Not available for the original: it uses Hardened Runtime and doesn't allow PluralMac Plus to redirect its preferences. Chromium and Electron apps keep their real settings in the profile folder, which is separated anyway. Otherwise you can run the instance from a private copy."
             : "Keeps the app's settings (UserDefaults) in the data folder instead of sharing them with other instances. Applies after restarting the instance.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    
    @ViewBuilder
    private var deviceIDRows: some View {
        Toggle("Separate device ID", isOn: Binding(
            get: { instance.hardwareIDOverride != nil },
            set: { enabled in
                Task { await viewModel.setSeparateHardwareID(instance, enabled: enabled) }
            }
        ))
        
        if let deviceID = instance.hardwareIDOverride {
            DetailRow(label: "Device ID", value: deviceID.uuidString)
                .contextMenu {
                    Button("Copy Device ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(deviceID.uuidString, forType: .string)
                    }
                }
            Button("New Device ID...") {
                confirmNewDeviceID = true
            }
            .confirmationDialog("Create a new device ID?", isPresented: $confirmNewDeviceID, titleVisibility: .visible) {
                Button("Create New Device ID") {
                    Task { await viewModel.regenerateHardwareID(instance) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The app will see a different device the next time it starts. You may have to sign in or confirm the device again.")
            }
        }
        
        Text(isRunning
             ? "Reports its own hardware ID to apps that identify the Mac that way. Changes apply after restarting the instance."
             : "Reports its own hardware ID to apps that identify the Mac that way, so several instances don't count as the same device.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    
    // MARK: - Launcher Section
    
    private var launcherSection: some View {
        DetailSection(title: "Launcher App") {
            if viewModel.hasLauncher(instance), let launcher = instance.launcherPath {
                DetailRow(label: "Location", value: launcher.path)
                    .contextMenu {
                        Button("Show in Finder") {
                            viewModel.revealLauncherInFinder(instance)
                        }
                    }
                HStack(spacing: 8) {
                    Button("Show in Finder") {
                        viewModel.revealLauncherInFinder(instance)
                    }
                    Button("Recreate") {
                        Task {
                            await viewModel.createLauncher(for: instance, in: launcher.deletingLastPathComponent())
                        }
                    }
                    Button("Move...") {
                        createLauncher(startingAt: launcher.deletingLastPathComponent())
                    }
                    Button("Remove", role: .destructive) {
                        Task {
                            await viewModel.removeLauncher(for: instance)
                        }
                    }
                    .help("Moves the launcher app to the Trash")
                }
            } else {
                Text("A small app named \"\(instance.name)\" that starts this instance directly, e.g. from the Dock, Launchpad or Spotlight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Create Launcher App...") {
                    createLauncher()
                }
            }
            
            LauncherIconColorPicker(
                baseIcon: launcherBaseIcon,
                hue: $launcherIconHue
            )
            
            if launcherIconHue != instance.launcherIconHue {
                HStack(spacing: 8) {
                    Button("Apply Color") {
                        Task {
                            await viewModel.setLauncherIconHue(instance, hue: launcherIconHue)
                        }
                    }
                    Button("Revert") {
                        launcherIconHue = instance.launcherIconHue
                    }
                }
            }
        }
        .onAppear { launcherIconHue = instance.launcherIconHue }
        .onChange(of: instance.id) { _, _ in launcherIconHue = instance.launcherIconHue }
        .onChange(of: instance.launcherIconHue) { _, newValue in launcherIconHue = newValue }
    }
    
    /// Launcher icon in its original colors
    private var launcherBaseIcon: NSImage {
        var untinted = instance
        untinted.launcherIconHue = nil
        return viewModel.launcherIcon(for: untinted)
    }
    
    // MARK: - Launch Options Section
    
    private var launchOptionsSection: some View {
        DetailSection(title: "Environment Variables & Arguments") {
            ForEach(Array(instance.environmentVariables.keys.sorted()), id: \.self) { key in
                DetailRow(label: key, value: instance.environmentVariables[key] ?? "")
            }
            ForEach(Array(instance.commandLineArguments.enumerated()), id: \.offset) { _, argument in
                Text(argument)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if instance.environmentVariables.isEmpty && instance.commandLineArguments.isEmpty {
                Text("None. The isolation variables are added automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Edit...") {
                editedEnvironment = instance.environmentVariables
                editedArguments = instance.commandLineArguments
                showLaunchOptionsEditor = true
            }
        }
        .sheet(isPresented: $showLaunchOptionsEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit \(instance.name)")
                    .font(.title2)
                LaunchOptionsEditor(environment: $editedEnvironment, arguments: $editedArguments)
                Text("Changes apply the next time the instance starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        showLaunchOptionsEditor = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        var updated = instance
                        updated.environmentVariables = editedEnvironment
                        updated.commandLineArguments = editedArguments
                        updated.touch()
                        showLaunchOptionsEditor = false
                        Task {
                            try? await viewModel.updateInstance(updated)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 520)
        }
    }
    
    // MARK: - Timestamps Section
    
    private var timestampsSection: some View {
        DetailSection(title: "Information") {
            DetailRow(label: "Created", value: instance.createdAtFormatted)
            if let lastLaunched = instance.lastLaunchedAtFormatted {
                DetailRow(label: "Last Launched", value: lastLaunched)
            }
            DetailRow(label: "Instance ID", value: instance.id.uuidString)
                .contextMenu {
                    Button("Copy ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(instance.id.uuidString, forType: .string)
                    }
                }
        }
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button {
                    viewModel.revealInFinder(instance)
                } label: {
                    Label("Show Shortcut in Finder", systemImage: "folder")
                }
                
                Button {
                    viewModel.revealDataInFinder(instance)
                } label: {
                    Label("Show Data in Finder", systemImage: "folder.badge.gearshape")
                }
            } label: {
                Label("Finder", systemImage: "folder")
            }
            .help("Reveal in Finder")
            
            Menu {
                Button {
                    newName = instance.name
                    isRenaming = true
                } label: {
                    Label("Rename...", systemImage: "pencil")
                }
                
                Button {
                    duplicateName = "\(instance.name) Copy"
                    showDuplicateSheet = true
                } label: {
                    Label("Duplicate...", systemImage: "plus.square.on.square")
                }
                
                Button {
                    moveDataFolder()
                } label: {
                    Label("Move Data Folder...", systemImage: "externaldrive")
                }
                .disabled(isRunning || isMovingData)
                
                Button {
                    createLauncher()
                } label: {
                    Label("Create Launcher App...", systemImage: "app.badge")
                }
                
                Divider()
                
                Button {
                    exportInstance()
                } label: {
                    Label("Export...", systemImage: "square.and.arrow.up")
                }
                
                Divider()
                
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete...", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
    
    // MARK: - Actions
    
    private func createLauncher(startingAt folder: URL = LauncherFolderPicker.applicationsFolder) {
        guard let folder = LauncherFolderPicker.choose(for: instance.name, startingAt: folder) else { return }
        Task {
            await viewModel.createLauncher(for: instance, in: folder)
        }
    }
    
    private func moveDataFolder() {
        guard let parent = DataFolderPicker.chooseParent(for: instance) else { return }
        Task {
            await viewModel.moveDataFolder(instance, toParent: parent)
        }
    }
    
    private func exportInstance() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(instance.name).pluralmac.json"
        panel.title = "Export Instance"
        panel.message = "Choose a location to export the instance configuration"
        
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                try? await viewModel.exportInstances([instance], to: url)
            }
        }
    }
    
    // MARK: - Icon Loading
    
    @MainActor
    private func loadIcon() async {
        if instance.shortcutExists {
            appIcon = NSWorkspace.shared.icon(forFile: instance.shortcutPath.path)
        } else {
            appIcon = NSWorkspace.shared.icon(forFile: instance.targetAppPath.path)
        }
    }
}

// MARK: - Detail Section

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Detail Row

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            
            Text(value)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
            
            Spacer()
        }
        .font(.body)
    }
}

// MARK: - Preview

#Preview {
    let mockInstance = AppInstance(
        name: "Chrome Work",
        application: try! Application(from: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
    )
    
    return InstanceDetailView(
        instance: mockInstance,
        viewModel: InstanceViewModel()
    )
}
