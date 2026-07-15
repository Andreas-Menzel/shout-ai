// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import AppKit
import SwiftUI

/// Geometry of the built-in display's camera notch, used to place and shape the
/// dynamic-island pill so it appears to grow out of the notch.
enum NotchMetrics {
    /// The screen with a notch, else the main screen.
    static func screen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    /// `(width, height, hasNotch)` for a screen. On notchless displays we fall
    /// back to a small virtual notch so the effect still reads at the top centre.
    static func size(on screen: NSScreen) -> (width: CGFloat, height: CGFloat, hasNotch: Bool) {
        let top = screen.safeAreaInsets.top
        guard top > 0 else { return (180, 32, false) }
        // The notch spans the gap between the two menu-bar areas beside it.
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let width = screen.frame.width - left - right
        return (width, top, true)
    }

    static func current() -> (width: CGFloat, height: CGFloat, hasNotch: Bool) {
        guard let screen = screen() else { return (180, 32, false) }
        return size(on: screen)
    }
}

/// Fixed canvas for the dynamic-island window. The SwiftUI root pins itself to
/// exactly this size so the hosting view reports constant window-size extrema —
/// a size that changes during the constraint pass re-enters layout and crashes.
enum NotchPillLayout {
    // Tall enough that the island can expand into the profile list without the
    // window resizing (a changing window size re-enters layout and crashes).
    static let canvas = CGSize(width: 620, height: 360)
}

/// A pill that appears to grow out of the camera notch: pinned flush to the top
/// edge with square top corners (continuous with the notch) and rounded bottom
/// corners. The island sizes to its content — small for short states like
/// "Inserted", wider while recording with a live transcript — animating between
/// them, just like the classic capsule.
struct NotchPillView: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One value per discrete island size. The width comes from PillContent's
    /// `maxWidth` frames (fixed per phase), NOT the text length — so live text
    /// truncates within a fixed width instead of resizing the island per word.
    /// Transitions between these buckets are what we animate.
    private var sizeToken: Int {
        switch app.phase {
        case .idle: return 0
        case .recording:
            if app.isShowingVoiceProfileList { return 5 }
            return (app.settings.livePreview && !app.transcriptPreview.isEmpty) ? 2 : 1
        case .transcribing, .rewriting: return 3
        case .notice: return 4
        }
    }

    var body: some View {
        let notch = NotchMetrics.current()

        VStack(spacing: 0) {
            PillContent()
                .padding(.horizontal, 16)
                .padding(.top, notch.height + 6) // clear the physical notch
                .padding(.bottom, 10)
                .frame(minWidth: notch.width) // never narrower than the notch
                .pillSurface(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: Theme.pillCornerRadius,
                        bottomTrailingRadius: Theme.pillCornerRadius,
                        style: .continuous
                    )
                )

            Spacer(minLength: 0)
        }
        // Fixed canvas == the window content size, so the hosting view's
        // window-size extrema never change (a changing root size re-enters
        // layout and crashes). The island resizes within this canvas; the wide
        // proposal makes PillContent's maxWidth frames take their fixed width.
        .frame(width: NotchPillLayout.canvas.width, height: NotchPillLayout.canvas.height, alignment: .top)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : Theme.pillAnimation, value: sizeToken)
        // The list's awaiting ↔ unmatched header swap happens within one size
        // bucket, so it needs its own animation value.
        .animation(reduceMotion ? nil : Theme.pillAnimation, value: app.voiceDecision)
    }
}
