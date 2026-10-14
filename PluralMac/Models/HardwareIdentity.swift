//
//  HardwareIdentity.swift
//  PluralMac
//
//  Created by Knutwurst on 14.10.26.
//

import Foundation
import CryptoKit

/// Gives an instance its own hardware UUID.
///
/// Some apps derive their device ID from `ioreg … IOPlatformUUID`, run through `/bin/sh`
/// (e.g. via NSAppleScript "do shell script", which ignores PATH). Two instances then register
/// as the same device. bash imports functions exported as `BASH_FUNC_<name>%%`, so an exported
/// `ioreg` wrapper replaces just the platform UUID in the output of the real `ioreg`.
enum HardwareIdentity {

    static let environmentKey = "BASH_FUNC_ioreg%%"

    /// Stable separate ID for an instance, so switching the option off and on keeps the same ID
    static func separateID(for instanceID: UUID) -> UUID {
        let digest = SHA256.hash(data: Data("PluralMacPlus.hardware-id.\(instanceID.uuidString)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40 // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Exported bash function that reports `id` as IOPlatformUUID and leaves everything else untouched
    static func ioregFunction(reporting id: UUID) -> String {
        "() { /usr/sbin/ioreg \"$@\" | /usr/bin/sed 's/\"IOPlatformUUID\" = \"[^\"]*\"/\"IOPlatformUUID\" = \"\(id.uuidString)\"/'; }"
    }
}
