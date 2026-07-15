// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation
import Observation
import ServiceManagement
import ShoutCore

/// Visual style of the floating status pill.
enum PillStyle: String, CaseIterable {
    case classic
    case dynamicIsland

    var displayName: String {
        switch self {
        case .classic: return "Classic (floating)"
        case .dynamicIsland: return "Dynamic Island (notch)"
        }
    }
}

/// User preferences, persisted to UserDefaults.
@MainActor
@Observable
final class SettingsStore {
    private static let defaults = UserDefaults.standard

    var languageMode: LanguageMode {
        didSet { Self.defaults.set(languageMode.rawValue, forKey: "languageMode") }
    }
    var rewriteEnabled: Bool {
        didSet { Self.defaults.set(rewriteEnabled, forKey: "rewriteEnabled") }
    }
    /// Dictations shorter than this many words skip the LLM pass entirely.
    var minWordsForRewrite: Int {
        didSet { Self.defaults.set(minWordsForRewrite, forKey: "minWordsForRewrite") }
    }
    /// Enable switching the active profile by starting a dictation with a
    /// trigger phrase (e.g. "use profile summarize, …").
    var voiceProfileSwitch: Bool {
        didSet { Self.defaults.set(voiceProfileSwitch, forKey: "voiceProfileSwitch") }
    }
    /// The phrase that begins a spoken profile switch.
    var voiceSwitchTrigger: String {
        didSet { Self.defaults.set(voiceSwitchTrigger, forKey: "voiceSwitchTrigger") }
    }
    /// Comma-separated words that abandon a spoken switch in progress and return
    /// the rest of the utterance to ordinary dictation ("cancel, abbrechen").
    var voiceSwitchCancelWords: String {
        didSet { Self.defaults.set(voiceSwitchCancelWords, forKey: "voiceSwitchCancelWords") }
    }
    /// Keep a voice-switched profile active for later dictations (off = only for
    /// the dictation that switched).
    var voiceSwitchSticky: Bool {
        didSet { Self.defaults.set(voiceSwitchSticky, forKey: "voiceSwitchSticky") }
    }
    /// Fn presses shorter than this are taps; longer are hold-to-talk.
    var holdThreshold: Double {
        didSet { Self.defaults.set(holdThreshold, forKey: "holdThreshold") }
    }
    /// Window for the second tap of a double-tap.
    var doubleTapWindow: Double {
        didSet { Self.defaults.set(doubleTapWindow, forKey: "doubleTapWindow") }
    }
    var restoreClipboard: Bool {
        didSet { Self.defaults.set(restoreClipboard, forKey: "restoreClipboard") }
    }
    /// Permit sending transcripts to a REMOTE endpoint over plain http (clear
    /// text). Off by default: otherwise the API key and dictation text travel
    /// unencrypted and are readable by anyone on the network path. Loopback http
    /// (a local server) never leaves the Mac and is always allowed regardless.
    var allowInsecureHTTP: Bool {
        didSet { Self.defaults.set(allowInsecureHTTP, forKey: "allowInsecureHTTP") }
    }
    /// Keep a local on-device log of dictations (raw + cleaned text). Off writes
    /// nothing to disk.
    var saveHistory: Bool {
        didSet { Self.defaults.set(saveHistory, forKey: "saveHistory") }
    }
    /// Run interim transcription passes during recording to show live text in
    /// the pill, refining as you speak. Opt-in: costs extra CPU while dictating.
    var livePreview: Bool {
        didSet { Self.defaults.set(livePreview, forKey: "livePreview") }
    }
    /// Pause music (Spotify, Apple Music) while dictating and resume it after.
    /// Sung lyrics reaching the mic bleed into the transcript; pausing beats
    /// lowering the volume because faint vocals still get transcribed.
    var pauseMediaWhileDictating: Bool {
        didSet { Self.defaults.set(pauseMediaWhileDictating, forKey: "pauseMediaWhileDictating") }
    }
    var pillStyle: PillStyle {
        didSet { Self.defaults.set(pillStyle.rawValue, forKey: "pillStyle") }
    }
    /// Show the active profile's glyph next to the app icon in the menu bar —
    /// the only surface that answers "which profile is armed?" between
    /// dictations, where the pill is hidden.
    var showProfileInMenuBar: Bool {
        didSet { Self.defaults.set(showProfileInMenuBar, forKey: "showProfileInMenuBar") }
    }
    var glossary: [String] {
        didSet { Self.defaults.set(glossary, forKey: "glossary") }
    }
    var onboardingCompleted: Bool {
        didSet { Self.defaults.set(onboardingCompleted, forKey: "onboardingCompleted") }
    }
    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    init() {
        let d = Self.defaults
        languageMode = LanguageMode(rawValue: d.string(forKey: "languageMode") ?? "auto") ?? .auto
        rewriteEnabled = d.object(forKey: "rewriteEnabled") as? Bool ?? true
        minWordsForRewrite = d.object(forKey: "minWordsForRewrite") as? Int ?? 4
        voiceProfileSwitch = d.object(forKey: "voiceProfileSwitch") as? Bool ?? false
        voiceSwitchTrigger = d.string(forKey: "voiceSwitchTrigger") ?? "use profile"
        voiceSwitchCancelWords = d.string(forKey: "voiceSwitchCancelWords") ?? "cancel, abbrechen"
        voiceSwitchSticky = d.object(forKey: "voiceSwitchSticky") as? Bool ?? false
        // Generous by design: the fn key is a large corner key and lazy taps
        // run 0.3–0.5 s. Holds-to-talk are ≥1 s in practice, so 0.5 s cleanly
        // separates the gestures.
        holdThreshold = d.object(forKey: "holdThreshold") as? Double ?? 0.5
        doubleTapWindow = d.object(forKey: "doubleTapWindow") as? Double ?? 0.6
        restoreClipboard = d.object(forKey: "restoreClipboard") as? Bool ?? true
        allowInsecureHTTP = d.object(forKey: "allowInsecureHTTP") as? Bool ?? false
        saveHistory = d.object(forKey: "saveHistory") as? Bool ?? true
        livePreview = d.object(forKey: "livePreview") as? Bool ?? false
        pauseMediaWhileDictating = d.object(forKey: "pauseMediaWhileDictating") as? Bool ?? true
        pillStyle = PillStyle(rawValue: d.string(forKey: "pillStyle") ?? "") ?? .classic
        showProfileInMenuBar = d.object(forKey: "showProfileInMenuBar") as? Bool ?? true
        glossary = d.stringArray(forKey: "glossary") ?? []
        onboardingCompleted = d.bool(forKey: "onboardingCompleted")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Launch-at-login change failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
