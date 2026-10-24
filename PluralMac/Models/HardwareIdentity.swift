//
//  HardwareIdentity.swift
//  PluralMac
//
//  Created by Knutwurst on 14.10.26.
//

import Foundation
import CryptoKit

/// Some apps get their device ID from `ioreg … IOPlatformUUID` through /bin/sh (NSAppleScript's
/// "do shell script" ignores PATH), so two instances look like one device. bash imports functions
/// exported as `BASH_FUNC_<name>%%`, so an exported `ioreg` wrapper swaps out just that UUID.
enum HardwareIdentity {

    static let environmentKey = "BASH_FUNC_ioreg%%"

    /// derived from the instance ID, so toggling the option off and on keeps the same UUID
    static func separateID(for instanceID: UUID) -> UUID {
        let digest = SHA256.hash(data: Data("PluralMacPlus.hardware-id.\(instanceID.uuidString)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40 // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// the real ioreg with IOPlatformUUID replaced by `id`, rest untouched
    static func ioregFunction(reporting id: UUID) -> String {
        "() { /usr/sbin/ioreg \"$@\" | /usr/bin/sed 's/\"IOPlatformUUID\" = \"[^\"]*\"/\"IOPlatformUUID\" = \"\(id.uuidString)\"/'; }"
    }
}
