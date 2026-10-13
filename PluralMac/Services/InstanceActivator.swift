//
//  InstanceActivator.swift
//  PluralMac
//
//  Created by Knutwurst on 13.10.26.
//

import AppKit

/// Brings a running instance to the front, like clicking its icon in the Dock.
enum InstanceActivator {

    /// "Reopen" Apple Event addressed to one process. The Dock sends the same event on click;
    /// AppKit apps restore a minimized window when they have no other visible window.
    static func reopenEvent(for pid: pid_t) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    /// Unhides, reopens and activates `app`. Returns false if the app is gone.
    @discardableResult
    static func bringToFront(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated else { return false }

        if app.isHidden {
            app.unhide()
        }
        _ = try? reopenEvent(for: app.processIdentifier).sendEvent(options: [.noReply], timeout: 5)
        
        // macOS 14+ only lets the active app hand over activation
        NSApp.yieldActivation(to: app)
        return app.activate(options: [.activateAllWindows])
    }
}
