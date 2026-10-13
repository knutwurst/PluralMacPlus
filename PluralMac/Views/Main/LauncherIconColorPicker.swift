//
//  LauncherIconColorPicker.swift
//  PluralMac
//
//  Created by Knutwurst on 13.10.26.
//

import SwiftUI
import AppKit

/// Hue slider with a live preview of the launcher icon.
struct LauncherIconColorPicker: View {

    /// Icon in its original colors
    let baseIcon: NSImage

    /// Hue rotation in degrees (nil = original colors)
    @Binding var hue: Double?

    /// Small copy of the icon, so the preview stays fast while dragging
    private var previewBase: NSImage {
        let preview = baseIcon.copy() as! NSImage
        preview.size = NSSize(width: 64, height: 64)
        return preview
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: hue.map { LauncherBuilder.tinted(previewBase, hueDegrees: $0) } ?? previewBase)
                .resizable()
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Slider(
                    value: Binding(get: { hue ?? 0 }, set: { hue = $0 }),
                    in: 0...359
                ) {
                    Text("Icon Color")
                }

                HStack {
                    Text(hue == nil ? "Original colors" : "Hue shifted by \(Int(hue ?? 0))°")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Original") {
                        hue = nil
                    }
                    .disabled(hue == nil)
                }
            }
        }
    }
}
