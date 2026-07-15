// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation

/// Engine abstraction seam.
///
/// The app depends only on these protocols, never on a concrete backend, so
/// swapping the speech-to-text or rewrite model is a new conformer plus one line
/// in `EngineFactory` — no changes to `AppState`, the pipeline, or the UI.

// MARK: - Transcription

public struct TranscriptionResult: Sendable {
    public let text: String
    /// ISO language code the audio was recognized as ("de", "en", …).
    public let languageCode: String

    public init(text: String, languageCode: String) {
        self.text = text
        self.languageCode = languageCode
    }
}

/// Turns 16 kHz mono Float32 samples into text. A backend may be local (whisper)
/// or network-backed; `transcribe` is `async` so either fits.
public protocol TranscriptionEngine: AnyObject, Sendable {
    /// Ready to transcribe right now (e.g. the model is resident). Must be cheap
    /// and non-blocking — never synchronize onto a work queue to answer it.
    var isReady: Bool { get }

    /// Bring the engine to `isReady` (load the model, open a session, …).
    /// Safe to call repeatedly; a no-op once ready.
    func prepare() async throws

    func transcribe(
        samples: [Float],
        language: LanguageMode,
        glossary: [String]
    ) async throws -> TranscriptionResult
}

// MARK: - Rewrite

/// Availability of a rewrite backend, expressed richly enough for both an
/// on-device model ("Apple Intelligence is off") and a network one ("offline").
public enum EngineAvailability: Sendable, Equatable {
    case available
    case unavailable(String)   // human-readable reason
}

/// Cleans a raw dictation transcript into fluent written text. Meaning-preserving
/// by contract; the caller falls back to the raw transcript when unavailable or
/// on error, so no rewrite backend may ever be load-bearing for correctness.
public protocol RewriteEngine: AnyObject, Sendable {
    var availability: EngineAvailability { get }
    /// Longest transcript (in characters) worth sending; longer inputs skip the
    /// model and pass through raw. Small on-device contexts are tight; endpoints
    /// are effectively unbounded.
    var maxInputCharacters: Int { get }
    /// Wall-clock budget the pipeline grants one rewrite before falling back to
    /// the raw transcript. Engine-specific because "too slow" means different
    /// things: the on-device model overrunning its ceiling is stuck, while a
    /// big endpoint model streaming steadily is just slow.
    var rewriteDeadline: TimeInterval { get }
    /// Warm any resident session with the system instructions the next rewrite
    /// will use, so the first real call doesn't pay cold-start cost.
    func prewarm(instructions: String)
    /// Run one completion and return the model's raw text. Prompt-building and
    /// quality guards live in `rewrite(profile:…)` — they're profile-driven, not
    /// engine-specific — so a backend only implements this primitive.
    func complete(system: String, user: String) async throws -> String
}

public extension RewriteEngine {
    var rewriteDeadline: TimeInterval { Tuning.rewriteTimeout }

    var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }
    var availabilityDescription: String {
        switch availability {
        case .available: return "Available"
        case .unavailable(let reason): return reason
        }
    }

    /// Full profile-driven rewrite: build the prompt, run the model, clean up
    /// the output, and apply the profile's guards. Returns the raw transcript
    /// unchanged when the input is too long, the output is empty, or a guard
    /// trips — the rewrite is never load-bearing for correctness.
    func rewrite(profile: Profile, transcript: String, languageCode: String?, glossary: [String]) async throws -> String {
        guard isAvailable else { throw ShoutError.rewriteUnavailable }
        guard transcript.count < maxInputCharacters else { return transcript }
        let prompt = profile.buildPrompt(transcript: transcript, languageCode: languageCode, glossary: glossary)
        let raw = try await complete(system: prompt.system, user: prompt.user)
        let cleaned = RewriteSupport.postprocess(raw)
        guard !cleaned.isEmpty else { return transcript }
        guard profile.guardrails.approve(cleaned: cleaned, original: transcript) else {
            Log.rewrite.info("Rewrite tripped a profile guard; keeping raw transcript")
            return transcript
        }
        return cleaned
    }
}

// MARK: - Engine construction

/// Constructs the concrete engines. The single place that maps a model entry to
/// its backend.
public enum EngineFactory {
    public static func makeTranscriber(modelURL: URL) -> any TranscriptionEngine {
        WhisperTranscriber(modelURL: modelURL)
    }

    /// Builds the rewrite engine for a model entry. Any API key is resolved by
    /// the caller from the Keychain and passed in, so this stays free of secret
    /// storage. `allowInsecureHTTP` carries the app's clear-text opt-in through
    /// to the endpoint engine (see `SettingsStore.allowInsecureHTTP`).
    public static func makeRewriter(for entry: ModelEntry, apiKey: String? = nil,
                                    allowInsecureHTTP: Bool = true) -> any RewriteEngine {
        switch entry.kind {
        case .appleFoundation:
            return AppleFoundationRewriter()
        case .endpoint(let config):
            return EndpointRewriter(config: config, apiKey: apiKey, allowInsecureHTTP: allowInsecureHTTP)
        }
    }
}

// MARK: - Tuning

/// Central home for the pipeline's tuned magic numbers, so they are named,
/// documented, and changed in one place.
public enum Tuning {
    /// Hard ceiling on the on-device rewrite, and the endpoint engine's IDLE
    /// timeout (longest gap between streamed chunks); a stuck model can't
    /// wedge the UI.
    public static let rewriteTimeout: TimeInterval = 25
    /// Wall-clock budget for one endpoint rewrite (`rewriteDeadline`). Much
    /// larger than `rewriteTimeout` because a big server model is often slow
    /// while visibly alive: the response streams, so the idle timeout above
    /// still fails a dead server fast, and this only bounds the total wait for
    /// a model that keeps generating (Esc bails out earlier by hand).
    public static let endpointRewriteTimeout: TimeInterval = 120
    /// Transcripts longer than this pass through raw. Kept well inside the
    /// on-device model's 4,096-token context once the ~800-token instructions
    /// and the model's own output are counted, so a long dictation fails fast to
    /// raw instead of wasting an attempt that would overflow. Used by the
    /// on-device engine; endpoints report their own (effectively unbounded)
    /// `maxInputCharacters`.
    public static let maxRewriteCharacters = 4000
    /// Response cap sent as `max_tokens` with every endpoint request. Servers
    /// like LM Studio apply a per-model response limit when the client names
    /// none, and a reasoning model can spend a small server cap entirely on
    /// `reasoning_content`, returning empty `content`. The explicit client value
    /// takes precedence; generous because a rewrite never comes near it.
    public static let endpointMaxTokens = 4096
    /// Upper bound on the glossary hint fed to whisper's `initial_prompt`.
    public static let whisperGlossaryPromptCap = 600
    /// Mean-square amplitude below which audio is treated as silence. Chosen
    /// empirically: quiet room noise sits under it, a spoken word well over it.
    /// Whisper hallucinates confident phrases on true silence, so we skip it.
    public static let silenceRMSThreshold: Float = 0.0015
    /// Fixed gain mapping mic RMS (which peaks well below 1.0 for normal speech)
    /// onto the 0…1 range the level meter draws. Empirical: ~0.11 RMS → full bar.
    public static let audioLevelGain: Float = 9
    /// Recordings shorter than this are discarded as accidental taps.
    public static let minDictationDuration: TimeInterval = 0.4
    /// A hands-free (locked) recording auto-finishes after this long so a
    /// walk-away session can't grow the audio buffer without bound.
    public static let maxDictationDuration: TimeInterval = 300
    /// While recording with live preview on, transcribe at most this many
    /// trailing seconds so each interim pass stays cheap.
    public static let previewWindowSeconds: Double = 20
    /// Minimum audio before an interim preview pass is worth running.
    public static let previewMinSeconds: Double = 0.4
    /// Audio prefix the live profile-switch classifier examines. The command
    /// grammar only ever matches at the utterance start, so the head is all
    /// that matters — and once the take outgrows this window the head audio is
    /// frozen: one last classification decides for good and head decodes stop.
    /// Generous (a slow pick from the pill list can take a while) but capped so
    /// interim passes stay cheap.
    public static let voiceCommandHeadSeconds: Double = 20
    /// How many words after the switch trigger are scanned for a profile
    /// name/number or a cancel word. Wide enough that a garbled first attempt
    /// plus its correction fit in the same breath ("use profile zummarize…
    /// ähm, Summarize"); narrow enough that a profile name spoken deep inside
    /// ordinary dictation can't hijack the take.
    public static let voiceCommandScanWindowTokens = 6
    /// A failed switch with at most this many words after the trigger was just
    /// a botched command — insert nothing. Longer failures keep everything
    /// after the trigger: silently dropping real dictation is worse than
    /// keeping a couple of stray words.
    public static let voiceCommandDropThresholdTokens = 2
}
