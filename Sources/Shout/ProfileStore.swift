// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation
import Observation
import ShoutCore

/// Owns the user's post-processing profiles and which one is active. Seeds the
/// built-ins on first run (and adds any new built-ins on upgrade), persists the
/// full set to UserDefaults, and supports create / duplicate / edit / delete.
@MainActor
@Observable
final class ProfileStore {
    private static let defaults = UserDefaults.standard
    private static let profilesKey = "profiles"
    private static let activeKey = "activeProfileID"

    private(set) var profiles: [Profile]

    /// The profile applied to a dictation when nothing overrides it.
    var activeID: String {
        didSet { Self.defaults.set(activeID, forKey: Self.activeKey) }
    }

    init() {
        let stored = Self.defaults.data(forKey: Self.profilesKey)
            .flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        // Upgrade built-ins the user never customized to the current shipped
        // prompts, then seed on first run and add built-ins introduced in a
        // later version — without clobbering the user's edits to existing ones.
        let upgrade = Profile.upgradeBuiltIns(stored)
        var merged = upgrade.profiles
        for builtIn in Profile.builtIns where !merged.contains(where: { $0.id == builtIn.id }) {
            merged.append(builtIn)
        }
        profiles = merged
        activeID = Self.defaults.string(forKey: Self.activeKey) ?? Profile.cleanUpID
        if stored.count != merged.count || upgrade.didUpgrade { persist() }
    }

    var active: Profile { profiles.first { $0.id == activeID } ?? profiles.first ?? .cleanUp }

    func profile(id: String) -> Profile? { profiles.first { $0.id == id } }

    /// Creates a new profile copied from `template` (default Clean-up) and
    /// returns its id.
    @discardableResult
    func addProfile(name: String, basedOn template: Profile = .cleanUp) -> String {
        let id = "user-" + UUID().uuidString
        profiles.append(Profile(
            id: id, name: name, taskPrompt: template.taskPrompt, rawPrompt: template.rawPrompt,
            modelID: template.modelID, guardrails: template.guardrails, isBuiltIn: false))
        persist()
        return id
    }

    /// Duplicates any profile (built-in or user) as a new editable user profile.
    @discardableResult
    func duplicate(id: String) -> String? {
        guard let source = profile(id: id) else { return nil }
        let newID = "user-" + UUID().uuidString
        var copy = source
        copy.id = newID
        copy.name = source.name + " copy"
        copy.isBuiltIn = false
        profiles.append(copy)
        persist()
        return newID
    }

    func update(_ profile: Profile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        persist()
    }

    /// Inserts a new profile or replaces an existing one with the same id.
    func save(_ profile: Profile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        persist()
    }

    /// Removes a user profile. Built-ins can't be deleted (only edited/reset).
    func remove(id: String) {
        guard let profile = profile(id: id), !profile.isBuiltIn else { return }
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = Profile.cleanUpID }
        persist()
    }

    /// Restores an edited built-in to its shipped defaults.
    func resetToDefault(id: String) {
        guard let builtIn = Profile.builtIns.first(where: { $0.id == id }),
              let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx] = builtIn
        persist()
    }

    private func persist() {
        Self.defaults.set(try? JSONEncoder().encode(profiles), forKey: Self.profilesKey)
    }
}
