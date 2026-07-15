// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import SwiftUI

/// The single source of truth for Shout's visual style — colors, typography,
/// spacing, radii, shadows, and the shared pill surface. Everything visual
/// routes through here so the surfaces read as one family, state changes don't
/// "jump", and the look is tunable in one place.
enum Theme {
    /// 4-pt spacing scale.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // Brand / status colors.
    static let accent = Color.accentColor
    static let success = Color.green
    static let warning = Color.orange
    static let recording = Color.red
    static let polish = Color.yellow

    // The floating/notch pill surface.
    static let pillFill = Color.black.opacity(0.85)
    static let pillStroke = Color.white.opacity(0.14)
    static let pillStrokeWidth: CGFloat = 1
    static let pillCornerRadius: CGFloat = 20
    static let pillShadowColor = Color.black.opacity(0.35)
    static let pillShadowRadius: CGFloat = 14
    static let pillShadowY: CGFloat = 5
    static let pillFont = Font.system(size: 13, weight: .medium)
    /// One spring for every pill state transition, so the two styles move alike.
    static let pillAnimation = Animation.spring(response: 0.4, dampingFraction: 0.82)

    // Metadata text (history rows + detail header) — one style, used in both.
    static let metaFont = Font.caption

    // Window content sizes (view and window agree via these).
    static let onboardingSize = CGSize(width: 560, height: 660)
    static let settingsSize = CGSize(width: 560, height: 540)
    static let historySize = CGSize(width: 860, height: 520)
}

extension View {
    /// Applies the shared pill surface (fill + hairline + shadow, dark scheme) in
    /// the given shape, so the classic capsule and the notch island are siblings.
    func pillSurface<S: Shape>(_ shape: S) -> some View {
        self
            .background(shape.fill(Theme.pillFill))
            .overlay(shape.stroke(Theme.pillStroke, lineWidth: Theme.pillStrokeWidth))
            .shadow(color: Theme.pillShadowColor, radius: Theme.pillShadowRadius, y: Theme.pillShadowY)
            .colorScheme(.dark)
    }
}
