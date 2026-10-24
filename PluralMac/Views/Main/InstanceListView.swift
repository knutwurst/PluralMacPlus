//
//  InstanceListView.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import SwiftUI

struct InstanceListView: View {
    
    @Bindable var viewModel: InstanceViewModel
    
    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedInstance?.id },
            set: { id in
                viewModel.selectedInstance = viewModel.instances.first { $0.id == id }
            }
        )) {
            ForEach(viewModel.filteredInstances) { instance in
                InstanceRowView(instance: instance, viewModel: viewModel)
                    .tag(instance.id)
            }
            .onDelete(perform: deleteInstances)
            // nil while searching, reordering a filtered list goes nowhere good
            .onMove(perform: moveHandler)
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenuContent(for: ids)
        } primaryAction: { ids in
            // Double-click: launch, or bring a running instance to the front
            if let id = ids.first,
               let instance = viewModel.instances.first(where: { $0.id == id }) {
                Task {
                    try? await viewModel.launchInstance(instance)
                }
            }
        }
    }
    
    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard viewModel.searchText.isEmpty else { return nil }
        return { source, destination in moveInstances(from: source, to: destination) }
    }
    
    private func moveInstances(from source: IndexSet, to destination: Int) {
        Task {
            await viewModel.moveInstances(from: source, to: destination)
        }
    }
    
    @ViewBuilder
    private func contextMenuContent(for ids: Set<UUID>) -> some View {
        let selectedInstances = viewModel.instances.filter { ids.contains($0.id) }
        
        if selectedInstances.count == 1, let instance = selectedInstances.first {
            Button {
                Task {
                    try? await viewModel.launchInstance(instance)
                }
            } label: {
                Label("Launch", systemImage: "play.fill")
            }
            
            Divider()
            
            Button {
                viewModel.revealDataInFinder(instance)
            } label: {
                Label(instance.redirectsHome ? "Show Data Folder" : "Show Profile Folder", systemImage: "folder.badge.gearshape")
            }
            
            Button {
                if let parent = DataFolderPicker.chooseParent(for: instance) {
                    Task {
                        await viewModel.moveDataFolder(instance, toParent: parent)
                    }
                }
            } label: {
                Label(instance.redirectsHome ? "Move Data Folder..." : "Move Profile Folder...", systemImage: "externaldrive")
            }
            .disabled(RunningInstancesManager.shared.isRunning(instance.id) || viewModel.instancesMovingData.contains(instance.id))
            
            // An instance with a private copy starts from the copy itself
            if instance.privateCopy == nil {
                Button {
                    if let folder = LauncherFolderPicker.choose(for: instance.name) {
                        Task {
                            await viewModel.createLauncher(for: instance, in: folder)
                        }
                    }
                } label: {
                    Label("Create Launcher App...", systemImage: "app.badge")
                }
            }
            
            Divider()
            
            Button {
                viewModel.select(instance)
                NotificationCenter.default.post(name: .renameSelectedInstance, object: nil)
            } label: {
                Label("Rename...", systemImage: "pencil")
            }
            
            Button {
                Task {
                    try? await viewModel.duplicateInstance(instance, newName: "\(instance.name) Copy")
                }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            
            Divider()
            
            Button(role: .destructive) {
                Task {
                    try? await viewModel.deleteInstance(instance, deleteData: false)
                }
            } label: {
                Label("Delete Shortcut", systemImage: "trash")
            }
            
            Button(role: .destructive) {
                Task {
                    try? await viewModel.deleteInstance(instance, deleteData: true)
                }
            } label: {
                Label("Delete Shortcut & Data", systemImage: "trash.fill")
            }
        } else if selectedInstances.count > 1 {
            Button(role: .destructive) {
                Task {
                    try? await viewModel.deleteInstances(selectedInstances, deleteData: false)
                }
            } label: {
                Label("Delete \(selectedInstances.count) Shortcuts", systemImage: "trash")
            }
        }
    }
    
    private func deleteInstances(at offsets: IndexSet) {
        let instancesToDelete = offsets.map { viewModel.filteredInstances[$0] }
        Task {
            try? await viewModel.deleteInstances(instancesToDelete, deleteData: false)
        }
    }
}

#Preview {
    @Previewable @State var viewModel = InstanceViewModel()
    
    InstanceListView(viewModel: viewModel)
        .frame(width: 280)
}
