//
//  RunningInstancesManager.swift
//  PluralMac
//
//  Maintained by Knutwurst.
//  Originally created by Rafael Alexander Mejia Blanco on 4/2/26.
//

import Foundation
import Combine
import OSLog

/// Which instances are running, published for SwiftUI
@MainActor
final class RunningInstancesManager: ObservableObject {
    
    static let shared = RunningInstancesManager()
    
    @Published private(set) var runningInstanceIds: Set<UUID> = []
    
    private let logger = Logger(subsystem: "com.knutwurst.PluralMacPlus", category: "RunningInstancesManager")
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    
    private init() {
        setupNotifications()
        startRefreshTimer()
    }
    
    func isRunning(_ instanceId: UUID) -> Bool {
        runningInstanceIds.contains(instanceId)
    }
    
    func markRunning(_ instanceId: UUID) {
        runningInstanceIds.insert(instanceId)
        logger.debug("Marked instance \(instanceId.uuidString) as running")
    }
    
    func markStopped(_ instanceId: UUID) {
        runningInstanceIds.remove(instanceId)
        logger.debug("Marked instance \(instanceId.uuidString) as stopped")
    }
    
    func refresh() async {
        let runningIds = await DirectLauncher.shared.runningInstanceIds()
        runningInstanceIds = Set(runningIds)
    }
    
    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .instanceTerminated)
            .compactMap { $0.userInfo?["instanceId"] as? UUID }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] instanceId in
                self?.markStopped(instanceId)
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: .instanceLaunched)
            .compactMap { $0.userInfo?["instanceId"] as? UUID }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] instanceId in
                self?.markRunning(instanceId)
            }
            .store(in: &cancellables)
    }
    
    private func startRefreshTimer() {
        // catches whatever the notifications missed
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }
    
    deinit {
        refreshTimer?.invalidate()
    }
}
