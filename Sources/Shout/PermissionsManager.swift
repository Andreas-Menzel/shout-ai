// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import AppKit
import ApplicationServices
import AVFoundation
import Observation
import ShoutCore

/// Live view of the permissions and system settings Shout depends on.
@MainActor
@Observable
final class PermissionsManager {
    var micStatus: AVAuthorizationStatus = .notDetermined
    var inputMonitoringGranted = false
    var accessibilityGranted = false
    /// System Settings › Keyboard › "Press 🌐 key to": 0 Do Nothing, 1 Change Input
    /// Source, 2 Show Emoji & Symbols, 3 Start Dictation. nil when unreadable.
    var fnUsageType: Int?

    var micGranted: Bool { micStatus == .authorized }
    var fnKeyConflictFree: Bool { fnUsageType == 0 }

    var fnUsageDescription: String {
        switch fnUsageType {
        case 0: return "Do Nothing — correct"
        case 1: return "Change Input Source — should be “Do Nothing”"
        case 2: return "Show Emoji & Symbols — should be “Do Nothing”"
        case 3: return "Start Dictation — conflicts with Shout, set to “Do Nothing”"
        default: return "Unknown — make sure it is “Do Nothing”"
        }
    }

    func refresh() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        // NOTE: the CG preflight functions are frozen for the process lifetime —
        // they keep returning false after the user grants the permission. Only
        // AXIsProcessTrusted() updates live; Input Monitoring truth comes from
        // whether the event tap could actually be created (AppState).
        inputMonitoringGranted = CGPreflightListenEventAccess()
        accessibilityGranted = AXIsProcessTrusted()
        fnUsageType = CFPreferencesCopyAppValue(
            "AppleFnUsageType" as CFString,
            "com.apple.HIToolbox" as CFString
        ) as? Int
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refresh()
    }

    /// Opens a Finder window with Shout.app selected, for dragging into the
    /// Input Monitoring list or picking it via the list's + button.
    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestPostEventAccess()
    }

    func openPrivacyPane(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() { openPrivacyPane("Privacy_Microphone") }
    func openInputMonitoringSettings() { openPrivacyPane("Privacy_ListenEvent") }
    func openAccessibilitySettings() { openPrivacyPane("Privacy_Accessibility") }

    func openKeyboardSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
