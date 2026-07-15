// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation
import Observation
import ShoutCore

struct HistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let raw: String
    let cleaned: String
    let language: String
    let appName: String
    let duration: Double
    let rewritten: Bool
}

/// Local dictation history, capped and persisted as JSON in Application Support.
@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    private let fileURL = ShoutPaths.appSupportDir.appendingPathComponent("history.json")
    private static let cap = 500

    init() {
        load()
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.cap {
            entries.removeLast(entries.count - Self.cap)
        }
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = decoded
        } else {
            // Don't silently wipe: quarantine the unreadable file so a partial
            // write or a schema change can be recovered, then start fresh.
            let quarantine = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.moveItem(at: fileURL, to: quarantine)
            Log.app.error("history.json unreadable; quarantined to \(quarantine.lastPathComponent, privacy: .public)")
            entries = []
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            // Dictation history is sensitive. Restrict it to the owner (FileVault
            // covers at-rest encryption) and keep it out of Time Machine / iCloud.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            Log.app.error("History save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
