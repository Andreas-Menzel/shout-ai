// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import SwiftUI
import ShoutCore

/// Permission + model + system-setting checklist. Used inside the onboarding
/// window and as the "Setup" tab in Settings.
struct SetupView: View {
    @Environment(AppState.self) private var app
    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    detail: "Records your voice while dictating",
                    granted: app.permissions.micGranted,
                    grant: { app.permissions.requestMicrophone() },
                    openSettings: { app.permissions.openMicrophoneSettings() }
                )
                inputMonitoringRow
                accessibilityRow
            }

            Section("Fn key") {
                HStack(alignment: .firstTextBaseline) {
                    statusIcon(app.permissions.fnKeyConflictFree)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("“Press 🌐 key to” must be “Do Nothing”")
                        Text("Currently: \(app.permissions.fnUsageDescription)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Keyboard Settings") {
                        app.permissions.openKeyboardSettings()
                    }
                }
                DisclosureGroup("Fine-tune timing") {
                    VStack(alignment: .leading) {
                        Slider(value: $settings.holdThreshold, in: 0.25...0.7, step: 0.05) {
                            Text("Hold threshold")
                        }
                        Text("Presses shorter than \(String(format: "%.2f", settings.holdThreshold)) s count as taps (double-tap = hands-free); longer presses are hold-to-talk.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Slider(value: $settings.doubleTapWindow, in: 0.3...1.0, step: 0.05) {
                            Text("Double-tap window")
                        }
                        Text("How long to wait for the second tap when locking hands-free mode (\(String(format: "%.2f", settings.doubleTapWindow)) s).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Speech model (Whisper large-v3-turbo, runs on-device)") {
                modelRow
            }

            Section("Polishing (cleans up your dictation)") {
                HStack(alignment: .firstTextBaseline) {
                    switch app.activeRewriteAvailability {
                    case .available:
                        statusIcon(true)
                        Text("Ready — dictations are polished before inserting")
                    case .unavailable(let reason):
                        statusIcon(false)
                        Text(reason)
                    }
                    Spacer()
                }
                if case .unavailable = app.activeRewriteAvailability {
                    Text("Without it, Shout still works and inserts the raw transcription.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            app.permissions.refresh()
            app.modelManager.refresh()
        }
        .onReceive(refreshTimer) { _ in
            app.permissions.refresh()
            app.modelManager.refresh()
        }
    }

    // Status shows GROUND TRUTH with three states: fully global (tap exists
    // AND Input Monitoring granted), degraded (tap exists via Accessibility
    // but macOS only delivers Shout's own keyboard — fn works solely while a
    // Shout window is focused), or inactive.
    private var inputMonitoringRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                statusIcon(app.fnGloballyActive)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Input Monitoring")
                    Text(inputMonitoringDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !app.fnGloballyActive {
                    Button("Grant") { app.requestInputMonitoring() }
                    Button("Reveal App") { app.permissions.revealAppInFinder() }
                }
            }
            if !app.fnGloballyActive {
                if app.fnMonitorActive {
                    Text("The listener could start (Accessibility allows that), but without Input Monitoring macOS only shows Shout its own keyboard — so the fn key works solely while a Shout window is in front. The steps below fix this.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text("""
                macOS shows no pop-up for this permission, a running app only picks a grant up after a restart, and entries from previous builds are dead:
                1. Click **Grant** — System Settings opens on the Input Monitoring list.
                2. **Remove** any existing Shout entry with **−**, then add it fresh with **+** (**Reveal App** shows you the file) and switch it on.
                3. Click **Restart Shout**, or accept macOS’s “Quit & Reopen”:
                """)
                .font(.callout)
                .foregroundStyle(.orange)
                HStack {
                    Spacer()
                    Button("Restart Shout") { app.restartApp() }
                }
            }
        }
    }

    private var inputMonitoringDetail: String {
        if app.fnGloballyActive { return "fn key listener is active system-wide" }
        if app.fnMonitorActive { return "fn key is currently seen only inside Shout" }
        return "Detects the fn key anywhere on the system"
    }

    private var accessibilityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                statusIcon(app.permissions.accessibilityGranted)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility")
                    Text("Inserts the finished text into the focused field")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !app.permissions.accessibilityGranted {
                    Button("Grant") { app.permissions.requestAccessibility() }
                    Button("Open Settings") { app.permissions.openAccessibilitySettings() }
                }
            }
            if !app.permissions.accessibilityGranted {
                Text("If Shout is already in the Accessibility list but this stays empty, the entry is stale from an earlier build: remove it with **−**, re-add it with **+**, and switch it on. This row updates live once the grant applies.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        switch app.modelManager.state {
        case .ready:
            HStack {
                statusIcon(true)
                Text("Installed")
                Spacer()
            }
        case .missing:
            HStack {
                statusIcon(false)
                Text("Not downloaded (1.6 GB, one time)")
                Spacer()
                Button("Download") { app.modelManager.startDownload() }
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading… \(Int(progress * 100))%")
                ProgressView(value: progress)
            }
        case .failed(let message):
            HStack {
                statusIcon(false)
                Text("Download failed: \(message)").foregroundStyle(.red)
                Spacer()
                Button("Retry") { app.modelManager.startDownload() }
            }
        }
    }

    private func statusIcon(_ ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(ok ? .green : .secondary)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let grant: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant") { grant() }
                Button("Open Settings") { openSettings() }
            }
        }
    }
}

/// First-launch wrapper around SetupView.
struct OnboardingView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
                Text("Welcome to Shout")
                    .font(.title.bold())
                Text("Hold the fn key and speak into any text field. Release, and polished text appears. Double-tap fn for hands-free mode; tap once to finish. Everything runs on your Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
            }
            .padding(.top, 24)
            .padding(.bottom, 8)

            SetupView()

            HStack {
                Spacer()
                Button(app.needsSetup ? "Finish later" : "Done") {
                    app.settings.onboardingCompleted = true
                    app.prewarm()
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: Theme.onboardingSize.width, height: Theme.onboardingSize.height)
    }
}
