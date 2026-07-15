// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import SwiftUI
import ShoutCore

/// Lists post-processing profiles with new / duplicate / edit / remove. Built-in
/// profiles can be edited or reset but not deleted. Any change re-applies the
/// selection so an edit to the active profile takes effect immediately.
struct ProfileManagerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var editorTarget: EditorTarget?

    enum EditorTarget: Identifiable {
        case add
        case edit(Profile)
        var id: String { if case .edit(let p) = self { return p.id }; return "add" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A profile decides how a dictation is transformed — its prompt, its model, and which guards apply.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(app.profiles.profiles) { profile in
                    row(profile).tag(profile.id)
                }
            }
            .frame(minHeight: 220)

            HStack {
                Button("New…") { editorTarget = .add }
                Button("Duplicate") {
                    if let selection, let id = app.profiles.duplicate(id: selection) { self.selection = id }
                }
                .disabled(selection == nil)
                Button("Edit…") {
                    if let selection, let profile = app.profiles.profile(id: selection) { editorTarget = .edit(profile) }
                }
                .disabled(selection == nil)
                Button("Remove") { remove() }
                    .disabled(!canRemoveSelection)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 500, height: 380)
        .sheet(item: $editorTarget) { target in
            Group {
                switch target {
                case .add: ProfileEditorView(profile: nil)
                case .edit(let profile): ProfileEditorView(profile: profile)
                }
            }
            .environment(app)
        }
    }

    private var canRemoveSelection: Bool {
        guard let selection, let profile = app.profiles.profile(id: selection) else { return false }
        return !profile.isBuiltIn
    }

    private func remove() {
        if let selection { app.profiles.remove(id: selection); app.reconfigureRewrite() }
        selection = nil
    }

    @ViewBuilder
    private func row(_ profile: Profile) -> some View {
        HStack {
            ProfileGlyphView(glyph: profile.glyph, font: .system(size: 15, weight: .medium))
                .frame(width: 22)
            VStack(alignment: .leading) {
                Text(profile.name)
                if let modelID = profile.modelID, let entry = app.modelRegistry.entry(id: modelID) {
                    Text("model: \(entry.displayName)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if profile.id == app.profiles.activeID {
                Text("active").font(.caption).foregroundStyle(.tint)
            }
            if profile.isBuiltIn {
                Text("built-in").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Add or edit one profile: name + task prompt, with model override, guardrail
/// toggles, and a raw-prompt escape hatch under Advanced.
struct ProfileEditorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    private let editingID: String?
    private let isBuiltIn: Bool

    @State private var name: String
    @State private var taskPrompt: String
    @State private var rawPrompt: String
    @State private var modelID: String?
    @State private var symbolName: String?
    @State private var tint: ProfileTint?
    @State private var lengthRatioGuard: Bool
    @State private var preserveTrailingQuestions: Bool
    @State private var enforceSameLanguage: Bool
    @State private var actAsAssistant: Bool

    init(profile: Profile?) {
        let base = profile ?? Profile(
            id: "", name: "New profile", taskPrompt: Profile.cleanUp.taskPrompt, guardrails: .strict)
        editingID = profile?.id
        isBuiltIn = profile?.isBuiltIn ?? false
        _name = State(initialValue: base.name)
        _taskPrompt = State(initialValue: base.taskPrompt)
        _rawPrompt = State(initialValue: base.rawPrompt ?? "")
        _modelID = State(initialValue: base.modelID)
        _symbolName = State(initialValue: base.symbolName)
        _tint = State(initialValue: base.tint)
        _lengthRatioGuard = State(initialValue: base.guardrails.lengthRatioGuard)
        _preserveTrailingQuestions = State(initialValue: base.guardrails.preserveTrailingQuestions)
        _enforceSameLanguage = State(initialValue: base.guardrails.enforceSameLanguage)
        _actAsAssistant = State(initialValue: base.guardrails.actAsAssistant)
    }

    /// What the profile will actually render as, resolved through the same
    /// fallback chain the app uses (shipped built-in glyph, name monogram) —
    /// so "no icon picked" previews truthfully, and live-updates with the name.
    private var previewGlyph: ProfileGlyph {
        Profile(id: editingID ?? "", name: name, taskPrompt: "",
                symbolName: symbolName, tint: tint, guardrails: .strict).glyph
    }

    /// Curated, deliberately old/stable SF Symbols: writing, communication,
    /// code, languages, documents, and a general-purpose tail.
    private static let symbolChoices: [String] = [
        "wand.and.stars", "briefcase", "terminal", "globe", "list.bullet.rectangle",
        "square.and.pencil", "pencil", "highlighter", "text.quote", "text.alignleft",
        "checklist", "doc.text", "doc.plaintext", "note.text", "book",
        "character.book.closed", "envelope", "paperplane", "bubble.left",
        "bubble.left.and.bubble.right", "quote.bubble", "speaker.wave.2", "waveform",
        "chevron.left.forwardslash.chevron.right", "curlybraces", "number", "at",
        "link", "magnifyingglass", "lightbulb", "graduationcap", "building.2",
        "person", "person.2", "heart", "star", "flag", "tag", "folder",
        "calendar", "clock", "bolt", "leaf", "music.note", "camera", "map",
        "airplane", "hammer", "paintbrush", "theatermasks",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                Section("Icon") {
                    HStack {
                        ProfileGlyphView(glyph: previewGlyph, font: .system(size: 20, weight: .medium))
                            .frame(width: 28)
                        Text("Shown in the pill and menu bar while this profile is active.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if symbolName != nil {
                            Button("Automatic") { symbolName = nil }
                                .help("Use the shipped icon for built-ins, or the name's first letter.")
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(ProfileTint.allCases, id: \.self) { choice in
                            Button {
                                tint = (tint == choice) ? nil : choice
                            } label: {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 20, height: 20)
                                    .overlay {
                                        if tint == choice {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    // Comfortable tap target around the small dot.
                                    .frame(width: 30, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Tint \(choice.rawValue)")
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 4)], spacing: 4) {
                        ForEach(Self.symbolChoices, id: \.self) { choice in
                            Button { symbolName = choice } label: {
                                Image(systemName: choice)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(symbolName == choice
                                        ? (tint?.color ?? Color.accentColor) : Color.secondary)
                                    .frame(width: 36, height: 32)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(symbolName == choice
                                                ? Color.secondary.opacity(0.18) : .clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice)
                        }
                    }
                }
                Section("Task") {
                    TextEditor(text: $taskPrompt)
                        .frame(minHeight: 120)
                        .font(.body.monospaced())
                    Text("What the model should do with the transcript. Wrapped in Shout's output-only scaffolding unless you set a raw prompt below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Guards") {
                    Toggle("Keep length close to the original", isOn: $lengthRatioGuard)
                    Toggle("Always keep a trailing question", isOn: $preserveTrailingQuestions)
                    Toggle("Keep the original language", isOn: $enforceSameLanguage)
                }
                DisclosureGroup("Advanced") {
                    Picker("Model", selection: $modelID) {
                        Text("Use default model").tag(String?.none)
                        ForEach(app.modelRegistry.entries) { entry in
                            Text(entry.displayName).tag(String?.some(entry.id))
                        }
                    }
                    Toggle("Let the model act on the content (assistant mode)", isOn: $actAsAssistant)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Raw prompt")
                        TextEditor(text: $rawPrompt)
                            .frame(minHeight: 80)
                            .font(.body.monospaced())
                        Text("If set, replaces the scaffolding + task entirely. You own the framing; Shout keeps only the \u{201C}output only the text\u{201D} rule.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if isBuiltIn, let editingID {
                    Button("Reset to default") {
                        app.profiles.resetToDefault(id: editingID)
                        app.reconfigureRewrite()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 520, height: 540)
    }

    private func save() {
        let trimmedRaw = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = Profile(
            id: editingID ?? ("user-" + UUID().uuidString),
            name: name.trimmingCharacters(in: .whitespaces),
            taskPrompt: taskPrompt,
            rawPrompt: trimmedRaw.isEmpty ? nil : rawPrompt,
            modelID: modelID,
            symbolName: symbolName,
            tint: tint,
            guardrails: GuardrailSettings(
                lengthRatioGuard: lengthRatioGuard,
                preserveTrailingQuestions: preserveTrailingQuestions,
                enforceSameLanguage: enforceSameLanguage,
                actAsAssistant: actAsAssistant),
            isBuiltIn: isBuiltIn)
        app.profiles.save(profile)
        app.reconfigureRewrite()
        dismiss()
    }
}
