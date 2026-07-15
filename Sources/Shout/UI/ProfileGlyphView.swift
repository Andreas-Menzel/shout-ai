// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import AppKit
import ShoutCore
import SwiftUI

extension ProfileTint {
    /// The single place a stored tint case becomes an on-screen color.
    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }
}

/// A profile's icon, rendered the same wherever profiles appear (pill, lists,
/// settings): the resolved SF Symbol in the profile's tint. `font` lets each
/// surface match its own type scale; untinted profiles take `fallbackTint` so
/// the glyph stays legible on both the dark pill and light settings surfaces.
struct ProfileGlyphView: View {
    let glyph: ProfileGlyph
    var font: Font = .system(size: 14, weight: .medium)
    var fallbackTint: Color = .primary

    var body: some View {
        Image(systemName: glyph.symbol)
            .font(font)
            .foregroundStyle(glyph.tint?.color ?? fallbackTint)
    }
}

/// Builds the dual-glyph menu bar image: the app-state symbol (the identity
/// anchor, unchanged) with the active profile's glyph beside it. Drawn into a
/// single template NSImage rather than composed SwiftUI views — MenuBarExtra
/// reliably renders one Image, and hand-drawing keeps spacing and relative
/// size deterministic. Template rendering means the menu bar recolors it for
/// light/dark/highlight; profile tints deliberately do not reach this surface.
@MainActor
enum MenuBarIcon {
    /// The profile glyph runs smaller than the state glyph and sits a hair
    /// apart, so the pair reads as one item with a companion badge — not as
    /// two neighboring menu bar extras.
    static func composite(stateSymbol: String, profileSymbol: String) -> NSImage {
        let state = symbolImage(stateSymbol, pointSize: 13.5)
        let profile = symbolImage(profileSymbol, pointSize: 11)
        let gap: CGFloat = 3.5
        let size = NSSize(width: state.size.width + gap + profile.size.width,
                          height: max(state.size.height, profile.size.height))
        let image = NSImage(size: size, flipped: false) { rect in
            state.draw(in: NSRect(x: 0, y: (rect.height - state.size.height) / 2,
                                  width: state.size.width, height: state.size.height))
            profile.draw(in: NSRect(x: state.size.width + gap,
                                    y: (rect.height - profile.size.height) / 2,
                                    width: profile.size.width, height: profile.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func symbolImage(_ name: String, pointSize: CGFloat) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        else { return NSImage(size: NSSize(width: pointSize, height: pointSize)) }
        return base.withSymbolConfiguration(config) ?? base
    }
}
