//
//  CreateInstanceView.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import SwiftUI
import UniformTypeIdentifiers

/// View for creating a new app instance.
/// Guides the user through selecting an app, naming the instance,
/// and configuring optional settings.
struct CreateInstanceView: View {
    
    // MARK: - Properties
    
    @Bindable var viewModel: InstanceViewModel
    @Environment(\.dismiss) private var dismiss
    
    // Form state
    @State private var selectedAppURL: URL?
    @State private var instanceName: String = ""
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var detectedApp: Application?
    
    // Advanced options
    @State private var showAdvancedOptions = false
    @State private var environmentVariables: [String: String] = [:]
    @State private var commandLineArguments: [String] = []
    @State private var customIconPath: URL?
    @State private var selectedIcon: NSImage?
    
    // Data folder (nil = default from Settings)
    @State private var customDataPath: URL?
    @State private var folderWithExistingData: URL?
    @State private var showReuseDialog = false
    @State private var dataFolderOwner: String?
    @State private var showFolderInUseAlert = false
    
    // Launcher app
    @State private var createLauncher = true
    @State private var launcherFolder = LauncherFolderPicker.applicationsFolder
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            Form {
                // App Selection Section
                appSelectionSection
                
                // Instance Name Section
                if detectedApp != nil {
                    instanceNameSection
                    dataFolderSection
                    launcherSection
                }
                
                // App Info Section
                if let app = detectedApp {
                    appInfoSection(app: app)
                }
                
                // Advanced Options
                if detectedApp != nil {
                    advancedOptionsSection
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 500, minHeight: 400)
            .navigationTitle("Create Instance")
            .confirmationDialog(
                "This folder already contains data",
                isPresented: $showReuseDialog,
                titleVisibility: .visible,
                presenting: folderWithExistingData
            ) { folder in
                Button("Use Existing Data") {
                    customDataPath = folder
                }
                Button("Choose Another Folder...") {
                    // Let the dialog close before opening the panel
                    DispatchQueue.main.async { chooseDataFolder() }
                }
                Button("Cancel", role: .cancel) {}
            } message: { folder in
                Text("\(folder.path)\n\nThe new instance can continue with this data, e.g. a profile from an earlier instance. Or choose another folder to start fresh. Nothing will be deleted.")
            }
            .alert("Folder already in use", isPresented: $showFolderInUseAlert) {
                Button("Choose Another Folder...") {
                    DispatchQueue.main.async { chooseDataFolder() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\"\(dataFolderOwner ?? "")\" already uses this folder. Two instances cannot share a data folder.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await createInstance()
                        }
                    }
                    .disabled(!canCreate)
                }
            }
        }
    }
    
    // MARK: - App Selection Section
    
    private var appSelectionSection: some View {
        Section {
            HStack {
                if let url = selectedAppURL {
                    // Show selected app
                    HStack(spacing: 12) {
                        appIcon(for: url)
                        
                        VStack(alignment: .leading) {
                            Text(url.deletingPathExtension().lastPathComponent)
                                .fontWeight(.medium)
                            Text(url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer()
                    
                    Button("Change") {
                        selectApp()
                    }
                } else {
                    // No app selected
                    Button {
                        selectApp()
                    } label: {
                        HStack {
                            Image(systemName: "plus.app")
                                .font(.title)
                            Text("Select Application")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            if let error = validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        } header: {
            Text("Application")
        } footer: {
            Text("Select the macOS application you want to create an instance of.")
        }
    }
    
    // MARK: - Instance Name Section
    
    private var instanceNameSection: some View {
        Section {
            TextField("Instance Name", text: $instanceName, prompt: Text("My Instance"))
                .textFieldStyle(.roundedBorder)
        } header: {
            Text("Instance Name")
        } footer: {
            Text("Give your instance a unique name to identify it.")
        }
    }
    
    // MARK: - Data Folder Section
    
    private var dataFolderSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let path = customDataPath {
                        Text(path.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if folderHasContents(path) {
                            Text("Existing data in this folder will be used.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Default")
                        Text(DataLocation.baseDirectory().path + "/…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                
                Spacer()
                
                if customDataPath != nil {
                    Button("Use Default") {
                        customDataPath = nil
                    }
                }
                
                Button("Choose...") {
                    chooseDataFolder()
                }
            }
        } header: {
            Text("Data Folder")
        } footer: {
            Text("Where this instance stores its profile, cache and login. Choose a folder that already contains data to reuse it.")
        }
    }
    
    // MARK: - Launcher Section
    
    private var launcherSection: some View {
        Section {
            Toggle("Create launcher app", isOn: $createLauncher)
            
            if createLauncher {
                HStack {
                    Text(launcherFolder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose...") {
                        let name = instanceName.trimmingCharacters(in: .whitespaces)
                        if let folder = LauncherFolderPicker.choose(for: name, startingAt: launcherFolder) {
                            launcherFolder = folder
                        }
                    }
                }
            }
        } header: {
            Text("Launcher App")
        } footer: {
            Text("A small app with the instance name that starts this instance directly, e.g. from the Dock, Launchpad or Spotlight.")
        }
    }
    
    // MARK: - App Info Section
    
    private func appInfoSection(app: Application) -> some View {
        Section {
            LabeledContent("App Type") {
                HStack {
                    Image(systemName: app.appType.compatibilityLevel.symbolName)
                        .foregroundStyle(compatibilityColor(for: app.appType.compatibilityLevel))
                    Text(app.appType.displayName)
                }
            }
            
            LabeledContent("Data Isolation") {
                Text(app.appType.isolationMethod.rawValue.capitalized)
            }
            
            LabeledContent("Bundle ID") {
                Text(app.bundleIdentifier)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Detected Configuration")
        }
    }
    
    // MARK: - Advanced Options Section
    
    private var advancedOptionsSection: some View {
        Section(isExpanded: $showAdvancedOptions) {
            // Environment Variables
            DisclosureGroup("Environment Variables") {
                environmentVariablesEditor
            }
            
            // Command Line Arguments
            DisclosureGroup("Command Line Arguments") {
                argumentsEditor
            }
            
            // Custom Icon
            VStack(alignment: .leading, spacing: 8) {
                Text("Instance Icon")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                IconPickerView(
                    selectedIcon: $selectedIcon,
                    customIconPath: $customIconPath,
                    sourceAppURL: selectedAppURL
                )
            }
            .padding(.vertical, 4)
        } header: {
            Text("Advanced Options")
        }
    }
    
    // MARK: - Environment Variables Editor
    
    private var environmentVariablesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(environmentVariables.keys.sorted()), id: \.self) { key in
                HStack {
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                    Text("=")
                        .foregroundStyle(.secondary)
                    Text(environmentVariables[key] ?? "")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        environmentVariables.removeValue(forKey: key)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Button {
                // TODO: Show add env var sheet
            } label: {
                Label("Add Variable", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Arguments Editor
    
    private var argumentsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(commandLineArguments, id: \.self) { arg in
                HStack {
                    Text(arg)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button {
                        commandLineArguments.removeAll { $0 == arg }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Button {
                // TODO: Show add argument sheet
            } label: {
                Label("Add Argument", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Helper Views
    
    @ViewBuilder
    private func appIcon(for url: URL) -> some View {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Image(nsImage: icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private func compatibilityColor(for level: CompatibilityLevel) -> Color {
        switch level {
        case .full: return .green
        case .partial: return .yellow
        case .unsupported: return .red
        }
    }
    
    // MARK: - Computed Properties
    
    private var canCreate: Bool {
        detectedApp != nil && !instanceName.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    // MARK: - Actions
    
    private func selectApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Select"
        panel.message = "Choose an application to create an instance of"
        
        if panel.runModal() == .OK, let url = panel.url {
            selectedAppURL = url
            validateApp(at: url)
        }
    }
    
    private func chooseDataFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = customDataPath ?? DataLocation.baseDirectory()
        panel.prompt = "Use Folder"
        panel.message = "Choose the data folder for this instance. Create a new folder or select one that already contains data."
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        if let owner = AppInstance.instance(usingDataPath: url, in: viewModel.instances) {
            dataFolderOwner = owner.name
            showFolderInUseAlert = true
        } else if folderHasContents(url) {
            folderWithExistingData = url
            showReuseDialog = true
        } else {
            customDataPath = url
        }
    }
    
    private func folderHasContents(_ url: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return contents.contains { $0 != ".DS_Store" }
    }
    
    private func validateApp(at url: URL) {
        isValidating = true
        validationError = nil
        detectedApp = nil
        
        do {
            let app = try Application(from: url)
            try app.validate()
            
            detectedApp = app
            
            // Auto-generate instance name
            if instanceName.isEmpty {
                instanceName = "\(app.name) Instance"
            }
        } catch {
            validationError = error.localizedDescription
        }
        
        isValidating = false
    }
    
    private func createInstance() async {
        guard let app = detectedApp else { return }
        
        let trimmedName = instanceName.trimmingCharacters(in: .whitespaces)
        
        do {
            try await viewModel.createInstance(
                name: trimmedName,
                application: app,
                environmentVariables: environmentVariables,
                arguments: commandLineArguments,
                customIconPath: customIconPath,
                dataPath: customDataPath,
                launcherFolder: createLauncher ? launcherFolder : nil
            )
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

// MARK: - Preview

#Preview {
    CreateInstanceView(viewModel: InstanceViewModel())
}
