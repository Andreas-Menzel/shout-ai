// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import AppKit
import SwiftUI

/// Owns the auxiliary windows (onboarding, history) for this accessory app.
@MainActor
final class WindowManager {
    private unowned let appState: AppState
    private var onboardingWindow: NSWindow?
    private var historyWindow: NSWindow?

    init(appState: AppState) {
        self.appState = appState
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let controller = NSHostingController(
                rootView: OnboardingView().environment(appState))
            let window = NSWindow(contentViewController: controller)
            window.title = "Set up Shout"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(Theme.onboardingSize)
            window.center()
            onboardingWindow = window
        }
        present(onboardingWindow)
    }

    func showHistory() {
        if historyWindow == nil {
            let controller = NSHostingController(
                rootView: HistoryView().environment(appState))
            let window = NSWindow(contentViewController: controller)
            window.title = "Dictation History"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(Theme.historySize)
            window.center()
            historyWindow = window
        }
        present(historyWindow)
    }

    private func present(_ window: NSWindow?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
