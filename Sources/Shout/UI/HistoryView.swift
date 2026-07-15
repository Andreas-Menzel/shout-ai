// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import SwiftUI

struct HistoryView: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var selectedID: HistoryEntry.ID?
    @State private var confirmingClear = false

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return app.history.entries }
        return app.history.entries.filter {
            $0.cleaned.localizedCaseInsensitiveContains(query)
                || $0.raw.localizedCaseInsensitiveContains(query)
                || $0.appName.localizedCaseInsensitiveContains(query)
        }
    }

    private var selected: HistoryEntry? {
        filtered.first { $0.id == selectedID } ?? app.history.entries.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search dictations…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer()
                Button("Clear All", role: .destructive) {
                    confirmingClear = true
                }
                .disabled(app.history.entries.isEmpty)
                .confirmationDialog(
                    "Delete all \(app.history.entries.count) dictations?",
                    isPresented: $confirmingClear, titleVisibility: .visible
                ) {
                    Button("Delete All", role: .destructive) {
                        app.history.clear()
                        selectedID = nil
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently removes your local dictation history and can't be undone.")
                }
            }
            .padding(10)

            Divider()

            HSplitView {
                List(filtered, selection: $selectedID) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.cleaned)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(entry.date, format: .dateTime.day().month().hour().minute())
                            Text("·")
                            Text(entry.appName)
                            Text("·")
                            Text(entry.language.uppercased())
                        }
                        .font(Theme.metaFont)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(entry.id)
                }
                .frame(minWidth: 280, idealWidth: 340)
                .overlay {
                    if app.history.entries.isEmpty {
                        ContentUnavailableView(
                            "No dictations yet",
                            systemImage: "mic",
                            description: Text("Hold fn and speak — your dictations show up here."))
                    }
                }

                detailPane
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let entry = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text(entry.date, format: .dateTime.weekday().day().month().year().hour().minute())
                        Text("·")
                        Text(entry.appName)
                        Text("·")
                        Text(String(format: "%.1f s", entry.duration))
                        if entry.rewritten {
                            Label("Polished", systemImage: "sparkles")
                                .foregroundStyle(Theme.polish)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            app.history.delete(entry.id)
                            selectedID = nil
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Delete this dictation")
                    }
                    .font(Theme.metaFont)
                    .foregroundStyle(.secondary)

                    transcriptBox(title: "Inserted text", text: entry.cleaned)
                    if entry.rewritten && entry.raw != entry.cleaned {
                        transcriptBox(title: "Raw transcript", text: entry.raw)
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView(
                "No dictation selected",
                systemImage: "text.quote",
                description: Text("Pick an entry to see the inserted text and the raw transcript.")
            )
        }
    }

    private func transcriptBox(title: String, text: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
            .padding(6)
        } label: {
            Text(title)
        }
    }
}
