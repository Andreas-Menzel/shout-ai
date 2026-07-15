// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(app.statusLine)

        // The active profile, one glance into the dropdown — present even with
        // the menu-bar glyph toggle off — with an inline switcher.
        Menu {
            Picker("Profile", selection: Binding(
                get: { app.profiles.activeID },
                set: { app.profiles.activeID = $0; app.reconfigureRewrite() }
            )) {
                ForEach(app.profiles.profiles) { profile in
                    Label(profile.name, systemImage: profile.glyph.symbol).tag(profile.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Profile: \(app.profiles.active.name)",
                  systemImage: app.profiles.active.glyph.symbol)
        }
        .disabled(!app.settings.rewriteEnabled)

        Divider()

        Button(app.phase.isRecording ? "Finish Dictation" : "Start Hands-free Dictation") {
            app.toggleDictation()
        }
        .disabled(app.phase.isBusy || (app.needsSetup && !app.phase.isRecording))

        Button(app.isPaused ? "Resume Shout" : "Pause Shout") {
            app.togglePause()
        }
        .help("Pause frees the fn key for other apps without quitting Shout.")

        Divider()

        Button("History…") {
            app.windows.showHistory()
        }

        Button("Setup Assistant…") {
            app.windows.showOnboarding()
        }

        Button("Settings…") {
            // Order the Settings window front, then foreground the app. Both run on
            // every click — that is what makes re-opening reliable for an accessory
            // app, even when the window is already open behind another app. (The
            // Settings scene alone only activates on first appearance.)
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit Shout") {
            NSApp.terminate(nil)
        }
    }
}
