//
//  AppEnvironment.swift
//  PluralMac
//
//  Created by Knutwurst on 14.10.26.
//

import Foundation

nonisolated enum AppEnvironment {

    /// PluralMac Plus is the unit test host. Then it must keep its hands off the user's instances:
    /// loading them also refreshes launchers and private copies on disk.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
