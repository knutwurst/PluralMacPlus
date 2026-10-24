//
//  Donation.swift
//  PluralMac
//
//  Created by Knutwurst on 17.10.26.
//

import AppKit

/// PayPal link for Settings → About, the Help menu and the sidebar. Opens on click only, no nagging.
enum Donation {
    static let url = URL(string: "https://paypal.me/oliverkoester")!

    static let note = "It doesn't have to be a big donation. A few cents show me who uses the tool and cares about where it goes next. That keeps me motivated, and I know I'm not coding for the bin ;)"

    static func open() {
        NSWorkspace.shared.open(url)
    }
}
