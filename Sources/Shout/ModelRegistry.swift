// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation
import Observation
import ShoutCore

/// The set of rewrite models the user can pick from: the always-present
/// on-device Apple model plus any endpoints they add. Endpoint entries and the
/// default selection persist to UserDefaults; API keys live in the Keychain,
/// keyed by entry id. Profiles reference an entry by id (`Profile.modelID`).
@MainActor
@Observable
final class ModelRegistry {
    private static let defaults = UserDefaults.standard
    private static let entriesKey = "rewriteModelEntries"
    private static let defaultIDKey = "rewriteDefaultModelID"

    /// User-added endpoint entries (the Apple entry is synthesized, not stored).
    private(set) var endpointEntries: [ModelEntry]

    /// Id of the model used when no profile overrides it.
    var defaultID: String {
        didSet { Self.defaults.set(defaultID, forKey: Self.defaultIDKey) }
    }

    init() {
        endpointEntries = Self.defaults.data(forKey: Self.entriesKey)
            .flatMap { try? JSONDecoder().decode([ModelEntry].self, from: $0) } ?? []
        defaultID = Self.defaults.string(forKey: Self.defaultIDKey) ?? ModelEntry.appleFoundationID
    }

    /// All selectable entries, Apple first.
    var entries: [ModelEntry] { [.appleFoundation] + endpointEntries }

    func entry(id: String) -> ModelEntry? { entries.first { $0.id == id } }

    /// The entry the default id points at, falling back to Apple if the stored
    /// id no longer resolves (e.g. its endpoint was deleted).

    // MARK: - Endpoint CRUD

    /// Adds an endpoint entry and returns its id.
    @discardableResult
    func addEndpoint(displayName: String, config: EndpointConfig, apiKey: String?) -> String {
        let id = "endpoint-" + UUID().uuidString
        endpointEntries.append(ModelEntry(id: id, displayName: displayName, kind: .endpoint(config)))
        KeychainStore.set(apiKey, account: id)
        persist()
        return id
    }

    /// Updates an endpoint entry. Pass `apiKey: nil` to leave the stored key
    /// untouched; pass `""` to clear it.
    func updateEndpoint(id: String, displayName: String, config: EndpointConfig, apiKey: String?) {
        guard let idx = endpointEntries.firstIndex(where: { $0.id == id }) else { return }
        endpointEntries[idx] = ModelEntry(id: id, displayName: displayName, kind: .endpoint(config))
        if let apiKey { KeychainStore.set(apiKey, account: id) }
        persist()
    }

    func removeEntry(id: String) {
        guard id != ModelEntry.appleFoundationID else { return }
        endpointEntries.removeAll { $0.id == id }
        KeychainStore.set(nil, account: id)
        if defaultID == id { defaultID = ModelEntry.appleFoundationID }
        persist()
    }

    // MARK: - API keys

    func apiKey(for id: String) -> String? { KeychainStore.get(account: id) }
    func hasAPIKey(for id: String) -> Bool { KeychainStore.hasKey(account: id) }

    private func persist() {
        Self.defaults.set(try? JSONEncoder().encode(endpointEntries), forKey: Self.entriesKey)
    }
}
