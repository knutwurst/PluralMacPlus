//
//  InstanceRowView.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import SwiftUI
import AppKit

struct InstanceRowView: View {
    
    let instance: AppInstance
    @Bindable var viewModel: InstanceViewModel
    
    @State private var appIcon: NSImage?
    @State private var isHovering = false
    
    @ObservedObject private var runningManager = RunningInstancesManager.shared
    
    private var isRunning: Bool {
        runningManager.isRunning(instance.id)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            iconView
            
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name)
                    .font(.headline)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    compatibilityIndicator
                    
                    Text(targetAppName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            if isRunning {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .help("Running")
            }
            
            if isHovering {
                if isRunning {
                    Button {
                        Task {
                            _ = await viewModel.terminateInstance(instance)
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop")
                } else {
                    Button {
                        Task {
                            try? await viewModel.launchInstance(instance)
                        }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Launch")
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .task(id: iconKey) {
            await loadIcon()
        }
    }
    
    @ViewBuilder
    private var iconView: some View {
        Group {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    private var compatibilityIndicator: some View {
        let level = instance.targetAppType.compatibilityLevel
        
        return Image(systemName: level.symbolName)
            .font(.caption2)
            .foregroundStyle(level.color)
            .help(instance.targetAppType.displayName)
    }

    private var targetAppName: String {
        instance.targetAppPath
            .deletingPathExtension()
            .lastPathComponent
    }
    
    // reloads the icon when its source or tint changes
    private var iconKey: String {
        "\(instance.customIconPath?.path ?? "")|\(instance.launcherIconHue ?? -1)"
    }
    
    @MainActor
    private func loadIcon() async {
        appIcon = viewModel.displayIcon(for: instance)
    }
}

#Preview {
    let mockInstance = AppInstance(
        name: "Chrome Work",
        application: try! Application(from: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
    )
    
    return InstanceRowView(
        instance: mockInstance,
        viewModel: InstanceViewModel()
    )
    .frame(width: 250)
    .padding()
}
