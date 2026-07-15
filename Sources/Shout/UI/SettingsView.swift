// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import SwiftUI
import ShoutCore

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            DictationSettingsTab()
                .tabItem { Label("Dictation", systemImage: "mic") }
            GlossaryTab()
                .tabItem { Label("Glossary", systemImage: "character.book.closed") }
            SetupView()
                .tabItem { Label("Setup", systemImage: "checklist") }
        }
        .frame(width: Theme.settingsSize.width, height: Theme.settingsSize.height)
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Startup") {
                Toggle("Launch Shout at login", isOn: $settings.launchAtLogin)
            }

            Section("Appearance") {
                Picker(selection: $settings.pillStyle) {
                    ForEach(PillStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                } label: {
                    Text("Pill style")
                    Text("Classic floats at the bottom of the screen; Dynamic Island docks it to the notch.")
                }
                Toggle(isOn: $settings.livePreview) {
                    Text("Show live transcript in the pill while speaking")
                    Text("Refines the words live as you talk. Uses more CPU while dictating.")
                }
                Toggle(isOn: $settings.showProfileInMenuBar) {
                    Text("Show active profile in the menu bar")
                    Text("Shows which profile will polish your next dictation.")
                }
            }

            Section("History") {
                Toggle(isOn: $settings.saveHistory) {
                    Text("Save dictation history")
                    Text("Keeps a local, on-device log you can review and re-copy. Turn off to store nothing.")
                }
                Button("Open History…") {
                    app.windows.showHistory()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DictationSettingsTab: View {
    @Environment(AppState.self) private var app
    @State private var showingEndpoints = false
    @State private var showingProfiles = false

    private var activeProfileName: String {
        app.profiles.profiles.first { $0.id == app.profiles.activeID }?.name ?? ""
    }

    private var defaultModelName: String {
        app.modelRegistry.entries.first { $0.id == app.modelRegistry.defaultID }?.displayName ?? ""
    }

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Language") {
                Picker("Spoken language", selection: $settings.languageMode) {
                    ForEach(LanguageMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("Polishing") {
                Toggle("Polish transcript before inserting", isOn: $settings.rewriteEnabled)

                LabeledContent("Profile") {
                    Menu {
                        Picker("Profile", selection: Binding(
                            get: { app.profiles.activeID },
                            set: { app.profiles.activeID = $0; app.reconfigureRewrite() }
                        )) {
                            ForEach(app.profiles.profiles) { profile in
                                Label(profile.name, systemImage: profile.glyph.symbol)
                                    .tag(profile.id)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()

                        Divider()
                        Button("Manage profiles…") { showingProfiles = true }
                    } label: {
                        HStack(spacing: 5) {
                            ProfileGlyphView(glyph: app.profiles.active.glyph,
                                             font: .system(size: 12, weight: .medium))
                            Text(activeProfileName)
                        }
                    }
                }
                .disabled(!settings.rewriteEnabled)

                LabeledContent("Default model") {
                    Menu {
                        Picker("Default model", selection: Binding(
                            get: { app.modelRegistry.defaultID },
                            set: { app.modelRegistry.defaultID = $0; app.reconfigureRewrite() }
                        )) {
                            ForEach(app.modelRegistry.entries) { entry in
                                Text(entry.displayName).tag(entry.id)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()

                        Divider()
                        Button("Manage endpoints…") { showingEndpoints = true }
                    } label: {
                        Text(defaultModelName)
                    }
                }
                .disabled(!settings.rewriteEnabled)

                if settings.rewriteEnabled {
                    ModelPrivacyNote(entry: app.activeEntry)
                }

                if settings.rewriteEnabled, case .unavailable(let reason) = app.activeRewriteAvailability {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.warning)
                }

                Stepper(value: $settings.minWordsForRewrite, in: 1...12) {
                    Text("Skip polishing below \(settings.minWordsForRewrite) words")
                }
                .disabled(!settings.rewriteEnabled)
            }

            Section("While dictating") {
                Toggle(isOn: $settings.pauseMediaWhileDictating) {
                    Text("Pause music while dictating")
                    Text("Pauses Spotify or Apple Music so lyrics don't bleed in, then resumes.")
                }
                Toggle(isOn: $settings.restoreClipboard) {
                    Text("Restore previous clipboard after inserting")
                    Text("Shout inserts text by pasting, then puts back whatever was on your clipboard.")
                }
            }

            Section("Voice profile switching") {
                Toggle("Switch profile by voice", isOn: $settings.voiceProfileSwitch)
                    .disabled(!settings.rewriteEnabled)
                if settings.voiceProfileSwitch {
                    TextField("Trigger phrase", text: $settings.voiceSwitchTrigger, prompt: Text("use profile"))
                        .disabled(!settings.rewriteEnabled)
                    TextField("Cancel words (comma-separated)", text: $settings.voiceSwitchCancelWords, prompt: Text("cancel, abbrechen"))
                        .disabled(!settings.rewriteEnabled)
                    Toggle("Keep the switched profile for later dictations", isOn: $settings.voiceSwitchSticky)
                        .disabled(!settings.rewriteEnabled)
                    Text("Start a dictation with the trigger and a profile name or number — \u{201C}use profile summarize, …\u{201D} or \u{201C}use profile two, …\u{201D}. The pill confirms the switch the moment it shows the name, with a soft tick — whatever the pill shows when you stop recording is exactly what runs. Misheard? Just say the name or a number again, or say a cancel word to keep dictating with the current profile.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingEndpoints) { EndpointManagerView().environment(app) }
        .sheet(isPresented: $showingProfiles) { ProfileManagerView().environment(app) }
    }
}

private struct GlossaryTab: View {
    @Environment(AppState.self) private var app
    @State private var newTerm = ""
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Names and jargon Shout should recognize and spell exactly — products, colleagues, technical terms.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(app.settings.glossary, id: \.self) { term in
                    Text(term).tag(term)
                }
            }
            .frame(minHeight: 220)

            HStack {
                TextField("Add term, e.g. Kubernetes", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Remove") {
                    if let selection {
                        app.settings.glossary.removeAll { $0 == selection }
                    }
                    selection = nil
                }
                .disabled(selection == nil)
            }
        }
        .padding()
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !app.settings.glossary.contains(term) else { return }
        app.settings.glossary.append(term)
        newTerm = ""
    }
}
