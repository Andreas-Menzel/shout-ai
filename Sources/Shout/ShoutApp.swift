// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import AppKit
import SwiftUI

/// Program entry point. In debug builds it diverts to the off-screen screenshot
/// renderer when `SHOUT_RENDER_DIR` / `SHOUT_RENDER_FRAMES` is set (documentation
/// tooling, compiled out of release); otherwise it launches the menu-bar app.
@main
enum ShoutMain {
    static func main() {
        #if DEBUG
        let handled = MainActor.assumeIsolated { ScreenshotRenderer.runIfRequested() }
        if handled { return }
        #endif
        ShoutApp.main()
    }
}

struct ShoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(delegate.appState)
        } label: {
            MenuBarLabel()
                .environment(delegate.appState)
        }

        Settings {
            SettingsView()
                .environment(delegate.appState)
        }
    }
}

struct MenuBarLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        // The dual glyph pairs the state icon (the stable anchor users locate
        // Shout by) with the active profile's symbol — the persistent answer
        // to "which profile is armed?" between dictations. The profile glyph
        // is a companion, never a replacement: a swapped-out anchor would both
        // break recognition and collide with other status items (a Translate
        // profile's globe reads as the system input-source switcher).
        if app.settings.showProfileInMenuBar {
            Image(nsImage: MenuBarIcon.composite(
                stateSymbol: app.menuBarSymbol,
                profileSymbol: app.profiles.active.glyph.symbol))
                .accessibilityLabel(
                    "Shout — \(app.statusLine) — profile \(app.profiles.active.name)")
        } else {
            Image(systemName: app.menuBarSymbol)
                .accessibilityLabel("Shout — \(app.statusLine)")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Self.retireOtherInstances()
        appState.startUp()
    }

    /// A second live Shout installs its own Fn-key hook and runs a parallel
    /// record → transcribe → switch → insert pipeline against the very same
    /// keypress. The two processes then have independent pills and resolve the
    /// profile switch independently, so one instance can drive the visible pill
    /// while the other performs the insertion — the pill and the end result stop
    /// agreeing. Exactly one pipeline may ever be live, so a newly launched
    /// instance retires any older ones (a rebuilt binary or a double-launch
    /// cleanly replaces the running copy rather than stacking on top of it).
    private static func retireOtherInstances() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let mine = NSRunningApplication.current.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where other.processIdentifier != mine {
            if !other.terminate() { other.forceTerminate() }
        }
    }
}
