// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import SwiftUI
import ShoutCore

/// One-line privacy note under the model picker: local models keep everything
/// on the Mac; an endpoint sends the transcript text off the machine.
struct ModelPrivacyNote: View {
    let entry: ModelEntry

    var body: some View {
        if entry.isLocal {
            Label("Runs on this Mac.", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Label(warningText, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Theme.warning)
        }
    }

    private var warningText: String {
        if case .endpoint(let config) = entry.kind, config.isInsecureRemote {
            return "Sends the transcript text to \(host) over plain http — it leaves your Mac unencrypted. (The audio never does.)"
        }
        return "Sends the transcript text to \(host) — it leaves your Mac. (The audio never does.)"
    }

    private var host: String {
        if case .endpoint(let config) = entry.kind { return config.baseURL.host ?? "the server" }
        return "the server"
    }
}

/// Lists the user's endpoints with add / edit / remove, mirroring the Glossary
/// tab's list pattern. Any change re-applies the model selection so a live edit
/// to the active model takes effect immediately.
struct EndpointManagerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var editorTarget: EditorTarget?

    enum EditorTarget: Identifiable {
        case add
        case edit(ModelEntry)
        var id: String { if case .edit(let e) = self { return e.id }; return "add" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OpenAI-compatible servers Shout can send transcripts to for cleanup — a local Ollama or LM Studio, or a remote server.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(app.modelRegistry.endpointEntries) { entry in
                    row(entry).tag(entry.id)
                }
            }
            .frame(minHeight: 200)
            .overlay {
                if app.modelRegistry.endpointEntries.isEmpty {
                    Text("No endpoints yet.").foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Add endpoint…") { editorTarget = .add }
                Button("Edit…") {
                    if let selection, let entry = app.modelRegistry.entry(id: selection) { editorTarget = .edit(entry) }
                }
                .disabled(selectedEntry == nil)
                Button("Remove") {
                    if let selection { app.modelRegistry.removeEntry(id: selection); app.reconfigureRewrite() }
                    selection = nil
                }
                .disabled(selection == nil)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460, height: 340)
        .sheet(item: $editorTarget) { target in
            Group {
                switch target {
                case .add:
                    EndpointEditorView(entry: nil, hasStoredKey: false)
                case .edit(let entry):
                    EndpointEditorView(entry: entry, hasStoredKey: app.modelRegistry.hasAPIKey(for: entry.id))
                }
            }
            .environment(app)
        }
    }

    private var selectedEntry: ModelEntry? {
        selection.flatMap { app.modelRegistry.entry(id: $0) }
    }

    @ViewBuilder
    private func row(_ entry: ModelEntry) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(entry.displayName)
                if case .endpoint(let config) = entry.kind {
                    Text(config.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(entry.isLocal ? "on this Mac" : "remote")
                .font(.caption)
                .foregroundStyle(entry.isLocal ? .secondary : Theme.warning)
        }
    }
}

private extension ReasoningEffort {
    var label: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// Add or edit a single endpoint. The API key field is write-only: when editing
/// an endpoint that already has a stored key, leaving it blank keeps the key;
/// typing replaces it; "Clear key" removes it.
struct EndpointEditorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    private let editingID: String?
    private let hasStoredKey: Bool

    @State private var name: String
    @State private var urlString: String
    @State private var model: String
    @State private var reasoningEffort: ReasoningEffort?
    @State private var apiKey: String = ""
    @State private var clearKey = false
    @State private var testState: TestState = .idle

    enum TestState: Equatable { case idle, testing, ok(String), failed(String) }

    init(entry: ModelEntry?, hasStoredKey: Bool) {
        editingID = entry?.id
        self.hasStoredKey = hasStoredKey
        if case .endpoint(let config)? = entry?.kind {
            _name = State(initialValue: entry?.displayName ?? "")
            _urlString = State(initialValue: config.baseURL.absoluteString)
            _model = State(initialValue: config.model)
            _reasoningEffort = State(initialValue: config.reasoningEffort)
        } else {
            _name = State(initialValue: "")
            _urlString = State(initialValue: "http://localhost:11434/v1")
            _model = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. Local Qwen3"))
                    TextField("Server URL", text: $urlString, prompt: Text("http://localhost:11434/v1"))
                        .autocorrectionDisabled()
                    TextField("Model", text: $model, prompt: Text("e.g. qwen3:4b"))
                        .autocorrectionDisabled()
                }
                Section {
                    Picker("Reasoning", selection: $reasoningEffort) {
                        Text("Server default").tag(ReasoningEffort?.none)
                        ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                            Text(effort.label).tag(ReasoningEffort?.some(effort))
                        }
                    }
                    Text("For thinking models — sent as reasoning_effort with each request. Off answers without a thinking pass, which is usually right for dictation. Ollama and OpenAI honor it; LM Studio currently ignores it (set reasoning per model in LM Studio instead); servers that don't know the field skip it silently.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    SecureField("API key", text: $apiKey,
                                prompt: Text(keyPlaceholder))
                        .disabled(clearKey)
                    if hasStoredKey {
                        Toggle("Remove stored key", isOn: $clearKey)
                    }
                    Text("Optional. Local servers like Ollama usually need none. Stored in your login keychain, never in plain settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Authentication")
                }
                if config?.isInsecureRemote == true {
                    Section {
                        Label("This is a remote server over plain http. Your API key and the dictation text would be sent in clear text — anyone on the network can read them. Prefer https.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.warning)
                        Toggle("Allow insecure HTTP to remote servers", isOn: allowInsecureBinding)
                    } header: {
                        Text("Insecure connection")
                    }
                }
                Section {
                    HStack {
                        Button("Test connection", action: test)
                            .disabled(config == nil || testState == .testing || blockedByInsecure)
                        if testState == .testing { ProgressView().controlSize(.small) }
                    }
                    testResult
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editingID == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(config == nil || blockedByInsecure)
            }
            .padding(12)
        }
        .frame(width: 460, height: 420)
    }

    private var keyPlaceholder: String {
        hasStoredKey ? "•••••••• (stored — leave blank to keep)" : "Optional"
    }

    /// Parsed config, or nil when the inputs aren't valid yet.
    private var config: EndpointConfig? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https",
              url.host?.isEmpty == false else { return nil }
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        guard !trimmedModel.isEmpty else { return nil }
        let candidate = EndpointConfig(baseURL: url, model: trimmedModel, reasoningEffort: reasoningEffort)
        return candidate.isConfigured ? candidate : nil
    }

    /// A remote clear-text endpoint the user hasn't opted into — blocks Save/Test.
    private var blockedByInsecure: Bool {
        (config?.isInsecureRemote ?? false) && !app.settings.allowInsecureHTTP
    }

    private var allowInsecureBinding: Binding<Bool> {
        Binding(get: { app.settings.allowInsecureHTTP },
                set: { app.settings.allowInsecureHTTP = $0 })
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle, .testing:
            EmptyView()
        case .ok(let reply):
            Label("Connected — replied \u{201C}\(reply.prefix(60))\u{201D}", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.callout)
                .foregroundStyle(Theme.warning)
        }
    }

    /// The key to send for a test: what's typed, else the stored key (unless the
    /// user is clearing it).
    private func keyForTest() -> String? {
        if !apiKey.isEmpty { return apiKey }
        if clearKey { return nil }
        return editingID.flatMap { app.modelRegistry.apiKey(for: $0) }
    }

    private func test() {
        guard let config else { return }
        let key = keyForTest()
        testState = .testing
        let allowInsecure = app.settings.allowInsecureHTTP
        Task {
            do {
                let reply = try await EndpointRewriter(
                    config: config, apiKey: key, allowInsecureHTTP: allowInsecure).testConnection()
                testState = .ok(reply)
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }

    private func save() {
        guard let config else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let displayName = trimmedName.isEmpty ? (config.baseURL.host ?? "Endpoint") : trimmedName
        // nil = leave the stored key unchanged; "" = clear it; else set the new key.
        let keyArg: String? = clearKey ? "" : (apiKey.isEmpty ? nil : apiKey)

        if let editingID {
            app.modelRegistry.updateEndpoint(id: editingID, displayName: displayName, config: config, apiKey: keyArg)
        } else {
            app.modelRegistry.addEndpoint(displayName: displayName, config: config, apiKey: apiKey.isEmpty ? nil : apiKey)
        }
        app.reconfigureRewrite()
        dismiss()
    }
}
