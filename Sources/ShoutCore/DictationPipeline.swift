// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation

/// Pairs the chosen engine with the active profile for one dictation. Resolved
/// per-run by the caller (the model can differ per profile), so the pipeline
/// stays free of model/profile selection.
public struct RewriteStep: Sendable {
    public let engine: any RewriteEngine
    public let profile: Profile
    public init(engine: any RewriteEngine, profile: Profile) {
        self.engine = engine
        self.profile = profile
    }
}

/// What to actually process, decided from the raw transcript: the (possibly
/// command-stripped) text and the rewrite step to run on it (nil to skip). Lets
/// the caller switch profiles from a spoken command before the polish stage.
public struct RewriteResolution: Sendable {
    public let text: String
    public let step: RewriteStep?
    public init(text: String, step: RewriteStep?) {
        self.text = text
        self.step = step
    }
}

/// The engine half of a dictation: transcribe → (optionally) rewrite →
/// deterministic normalize. Kept free of UI, insertion, and history so the
/// fallback logic (empty transcript, rewrite skipped/failed, cancellation) is
/// unit-testable with fake engines. `@MainActor` so the progress callbacks land
/// on the main actor for the caller's UI updates.
@MainActor
public final class DictationPipeline {
    public struct Outcome: Sendable {
        public let raw: String
        public let final: String
        public let languageCode: String
        /// The rewrite ran and was accepted.
        public let rewritten: Bool
        /// A rewrite was expected but didn't happen (AI off, timed out, or the
        /// quality guard reverted it) — the caller flags this as "raw".
        public let polishFellBack: Bool
    }

    private let transcriber: any TranscriptionEngine

    public init(transcriber: any TranscriptionEngine) {
        self.transcriber = transcriber
    }

    /// Returns nil when nothing was transcribed. Throws `CancellationError` if
    /// the surrounding task is cancelled (checked at each stage boundary).
    /// - resolve: given the raw transcript, returns the text to process and the
    ///   rewrite step; lets the caller strip a leading voice command and switch
    ///   profiles. Called once, synchronously, on the main actor.
    /// - onTranscribed: the normalized text to be inserted, for an immediate preview.
    /// - onRewriting: invoked when entering the (slower) polish stage.
    public func run(
        samples: [Float],
        language: LanguageMode,
        glossary: [String],
        rewriteEnabled: Bool,
        minWords: Int,
        resolve: (String) -> RewriteResolution,
        onTranscribed: (String) -> Void = { _ in },
        onRewriting: () -> Void = {}
    ) async throws -> Outcome? {
        if !transcriber.isReady { try await transcriber.prepare() }
        let result = try await transcriber.transcribe(
            samples: samples, language: language, glossary: glossary)
        try Task.checkCancellation()
        guard !result.text.isEmpty else { return nil }

        // Let the caller strip a leading voice command and pick the profile.
        let resolution = resolve(result.text)
        let effective = resolution.text

        // Surface what will actually be inserted, normalized like the final text
        // so the preview doesn't visibly "unfix" itself.
        onTranscribed(TextNormalizer.normalize(effective, glossary: glossary))

        var finalText = effective
        var rewritten = false
        var polishFellBack = false
        if let step = resolution.step, rewriteEnabled, wordCount(effective) >= minWords, step.engine.isAvailable {
            onRewriting()
            do {
                let text = effective
                let lang = result.languageCode
                let improved = try await withTimeout(seconds: step.engine.rewriteDeadline) { [step, glossary] in
                    try await step.engine.rewrite(
                        profile: step.profile, transcript: text, languageCode: lang, glossary: glossary)
                }
                if !improved.isEmpty {
                    finalText = improved
                    rewritten = true
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.rewrite.error("Rewrite failed, inserting raw transcript: \(error.localizedDescription, privacy: .public)")
            }
            polishFellBack = !rewritten
        }
        try Task.checkCancellation()

        // Deterministic last word on spelling/fillers — runs even when the
        // rewrite was disabled, skipped, or ignored the glossary.
        finalText = TextNormalizer.normalize(finalText, glossary: glossary)
        return Outcome(
            raw: result.text, final: finalText, languageCode: result.languageCode,
            rewritten: rewritten, polishFellBack: polishFellBack)
    }
}
