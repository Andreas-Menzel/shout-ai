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

    /// Warms the model with the exact instructions the next rewrite will use, so
    /// the ~800-token instruction prefill is cached and the first call is fast.
    public func prewarm(instructions: String) {
        guard isAvailable else { return }
        let session = LanguageModelSession(model: model, instructions: instructions)
        session.prewarm(promptPrefix: nil)
    }

    public func complete(system: String, user: String) async throws -> String {
        guard isAvailable else { throw ShoutError.rewriteUnavailable }
        let session = LanguageModelSession(model: model, instructions: system)
        let started = Date()
        let response = try await session.respond(to: user, options: GenerationOptions(sampling: .greedy))
        Log.rewrite.info("Rewrite took \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s")
        return response.content
    }
}
