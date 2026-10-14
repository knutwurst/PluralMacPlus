//
//  AppEnvironment.swift
//  PluralMac
//
//  Created by Knutwurst on 14.10.26.
//

import Foundation

nonisolated enum AppEnvironment {

    /// True when PluralMac Plus runs as the host app of the unit tests. It then must not load the
    /// user's instances, because loading also refreshes launchers and private copies on disk.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
