// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation
import FoundationModels

/// `RewriteEngine` backed by the on-device Apple Intelligence model. Runs the
/// profile-built prompt through the system language model and returns its raw
/// text; prompt assembly and guards live in the shared `rewrite(profile:…)`.
public final class AppleFoundationRewriter: RewriteEngine, Sendable {
    /// Content-transformation guardrails are purpose-built for a "rewrite this
    /// text" use case: they lift the default assistant safety filter that can
    /// refuse to process heated or profane dictation, while the profile's own
    /// framing keeps behavior bounded. Held once and reused for availability,
    /// prewarm, and completion so all three agree on the same configuration.
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    public init() {}

    public var availability: EngineAvailability {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .unavailable("Apple Intelligence is off — enable it in System Settings › Apple Intelligence & Siri")
            case .deviceNotEligible:
                return .unavailable("This Mac does not support Apple Intelligence")
            case .modelNotReady:
                return .unavailable("Apple Intelligence model is still preparing — try again in a minute")
            @unknown default:
                return .unavailable("Unavailable")
            }
        }
    }

    /// The on-device model's context is small; keep the transcript well inside it
    /// once instructions and output are counted, else pass through raw.
    public var maxInputCharacters: Int { Tuning.maxRewriteCharacters }

    /// Asks the system to load the on-device model's resources ahead of the first
    /// rewrite, so that cost isn't paid mid-dictation. Model residency is
    /// process-wide and does outlive this call.
    ///
    /// What it does *not* buy is a cached instruction prefill: prefill is per
    /// `LanguageModelSession`, and the session built here is deliberately thrown
    /// away — see `complete(system:user:)` for why we never reuse one.
    public func prewarm(instructions: String) {
        guard isAvailable else { return }
        let session = LanguageModelSession(model: model, instructions: instructions)
        session.prewarm(promptPrefix: nil)
    }

    /// A fresh session per rewrite, on purpose. `LanguageModelSession` accumulates
    /// a transcript, so a reused one would carry the previous dictation into the
    /// next one's context — leaking one dictation's content into another's result.
    /// Paying the prefill each time is the correct trade for that isolation.
    public func complete(system: String, user: String) async throws -> String {
        guard isAvailable else { throw ShoutError.rewriteUnavailable }
        let session = LanguageModelSession(model: model, instructions: system)
        let started = Date()
        let response = try await session.respond(to: user, options: GenerationOptions(sampling: .greedy))
        Log.rewrite.info("Rewrite took \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s")
        return response.content
    }
}
