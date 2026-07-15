// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation

/// Which meaning-preserving guards apply to a profile's output. These are
/// *opinions about the output* and are per-profile; the data-loss/liveness
/// invariants (error → raw fallback, timeout) live in the pipeline and are
/// always on, so turning every guard here off still can't lose the transcript.
public struct GuardrailSettings: Codable, Equatable, Sendable {
    /// Revert to raw if the result drops below half / grows past 1.5× the word
    /// count — catches dropped sentences and runaway additions. Off for a
    /// Summarize profile, whose whole job is to shrink.
    public var lengthRatioGuard: Bool
    /// Revert to raw if the speaker's trailing question ("…, oder?") vanished.
    public var preserveTrailingQuestions: Bool
    /// Pin the output to the transcript's language. Off for a Translate profile.
    public var enforceSameLanguage: Bool
    /// Let the model act on the transcript's content (e.g. a prompt-engineer
    /// profile) rather than treating it strictly as text to transform. The
    /// output is still only ever typed text, never an executed action.
    public var actAsAssistant: Bool

    public init(lengthRatioGuard: Bool, preserveTrailingQuestions: Bool,
                enforceSameLanguage: Bool, actAsAssistant: Bool) {
        self.lengthRatioGuard = lengthRatioGuard
        self.preserveTrailingQuestions = preserveTrailingQuestions
        self.enforceSameLanguage = enforceSameLanguage
        self.actAsAssistant = actAsAssistant
    }

    /// Whether the cleaned text is trustworthy under the enabled guards. `false`
    /// means the caller keeps the raw transcript.
    public func approve(cleaned: String, original: String) -> Bool {
        if lengthRatioGuard {
            let originalWords = wordCount(original)
            if originalWords > 0 {
                let ratio = Double(wordCount(cleaned)) / Double(originalWords)
                if ratio < 0.5 || ratio > 1.5 { return false }
            }
        }
        if preserveTrailingQuestions,
           RewriteSupport.endsWithQuestion(original), !RewriteSupport.endsWithQuestion(cleaned) {
            return false
        }
        return true
    }

    /// The strict, meaning-preserving defaults (the Clean-up contract).
    public static let strict = GuardrailSettings(
        lengthRatioGuard: true, preserveTrailingQuestions: true,
        enforceSameLanguage: true, actAsAssistant: false)
}

/// Accent color a profile's glyph can carry. Raw-value Codable so the stored
/// JSON stays a plain string; how a case maps to an actual color is the UI's
/// business (the menu bar, for one, always renders template/monochrome).
public enum ProfileTint: String, Codable, CaseIterable, Equatable, Sendable {
    case red, orange, yellow, green, mint, blue, indigo, purple, pink, gray
}

/// The resolved visual identity of a profile: always a renderable SF Symbol
/// (see `Profile.glyph` for the fallback chain) plus an optional tint.
public struct ProfileGlyph: Equatable, Sendable {
    public let symbol: String
    public let tint: ProfileTint?

    public init(symbol: String, tint: ProfileTint?) {
        self.symbol = symbol
        self.tint = tint
    }
}

/// A named post-processing configuration: a task prompt, optional model
/// override, and its guardrails. Built-ins ship editable; users can duplicate
/// and create their own. A profile drives *what* the rewrite does; the engine
/// drives *which model* runs it.
public struct Profile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Guided, editable description of the task. Wrapped in managed
    /// output-discipline scaffolding unless `rawPrompt` is set.
    public var taskPrompt: String
    /// Advanced: replaces the guided scaffolding + task prompt entirely. The
    /// only thing kept around it is the "output only the text" discipline.
    public var rawPrompt: String?
    /// Model entry id to run this profile on; nil = the registry default.
    public var modelID: String?
    public var guardrails: GuardrailSettings
    /// Built-ins are seeded and protected from deletion (still editable).
    public var isBuiltIn: Bool
    /// SF Symbol shown wherever the profile appears (pill, menu bar, lists).
    /// Optional so profiles stored before the icon feature keep decoding; nil
    /// resolves through `glyph`'s fallback chain.
    public var symbolName: String?
    /// Accent for the glyph in color-capable surfaces. Optional for the same
    /// backward-compatibility reason as `symbolName`.
    public var tint: ProfileTint?

    public init(id: String, name: String, taskPrompt: String, rawPrompt: String? = nil,
                modelID: String? = nil, symbolName: String? = nil, tint: ProfileTint? = nil,
                guardrails: GuardrailSettings, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.taskPrompt = taskPrompt
        self.rawPrompt = rawPrompt
        self.modelID = modelID
        self.symbolName = symbolName
        self.tint = tint
        self.guardrails = guardrails
        self.isBuiltIn = isBuiltIn
    }

    /// The glyph to render, never empty: the user's chosen symbol, else the
    /// shipped default for a built-in (stored copies predate the icon feature,
    /// so this stays a display-time fallback — no migration), else a letter
    /// monogram via the native `a.circle.fill` symbols, else a generic head.
    public var glyph: ProfileGlyph {
        let fallback = Profile.builtInGlyphs[id]
        if let symbolName, !symbolName.isEmpty {
            return ProfileGlyph(symbol: symbolName, tint: tint ?? fallback?.tint)
        }
        if let fallback {
            return ProfileGlyph(symbol: fallback.symbol, tint: tint ?? fallback.tint)
        }
        return ProfileGlyph(symbol: Self.monogramSymbol(for: name), tint: tint)
    }

    /// SF Symbols ship circled glyphs for a–z and 0–9; fold diacritics so
    /// "Übersetzen" still lands on "u.circle.fill". Anything else (emoji-first
    /// names, CJK) gets the generic profile head.
    static func monogramSymbol(for name: String) -> String {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard let first = folded.unicodeScalars.first,
              "abcdefghijklmnopqrstuvwxyz0123456789".unicodeScalars.contains(first)
        else { return "person.crop.circle.fill" }
        return "\(first).circle.fill"
    }

    /// Builds the (system, user) prompt pair the engine runs. Guided mode wraps
    /// the task in shared scaffolding; raw mode hands over control but keeps the
    /// output-only discipline so results stay insertable.
    public func buildPrompt(transcript: String, languageCode: String?, glossary: [String]) -> (system: String, user: String) {
        let system: String
        if let rawPrompt, !rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            system = rawPrompt + "\n\n" + RewriteSupport.outputOnlyLine + RewriteSupport.glossaryClause(glossary)
        } else {
            system = RewriteSupport.scaffolding(guardrails: guardrails)
                + "\n\n" + taskPrompt
                + RewriteSupport.glossaryClause(glossary)
        }
        let user = RewriteSupport.userPrompt(
            transcript: transcript,
            languageCode: guardrails.enforceSameLanguage ? languageCode : nil)
        return (system, user)
    }
}
