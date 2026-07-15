// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation

/// The per-take authority on voice profile switching: what the pill shows IS
/// what runs. Selection happens live, while recording — interim decodes of the
/// utterance head are classified and fed in via `apply`, and the first match
/// latches one-way. `freeze()` is called at key release; from that moment the
/// decision can never change, in either direction:
///
///   · latched  → that profile runs, even if the final decode garbles the
///     command (the final transcript is consulted only to locate the command
///     boundary for stripping — never to select);
///   · not latched → no switch, even if the final transcript plainly contains
///     one — acting on it would contradict what the pill showed the user.
///
/// This inversion (live wins, post-processing never selects) is deliberate:
/// the user watches the pill confirm the profile and then dictates with
/// confidence. A switch appearing — or changing — after speech ends is exactly
/// the surprise this type exists to make impossible.
public struct VoiceSwitchDecision: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// No trigger heard (yet) — ordinary dictation.
        case inactive
        /// Trigger heard, no profile named yet — the pill shows the list.
        case awaitingName
        /// Spoken words match nothing — list stays up with "isn't on the list".
        case unmatched(spoken: String)
        /// A cancel word abandoned the command; dictation continues.
        case cancelled
        /// A profile matched. One-way: nothing can overturn a shown badge.
        case latched(profileID: String, profileName: String)
    }

    public private(set) var state: State = .inactive
    /// Set at key release. A frozen decision ignores all further input, so an
    /// interim decode landing late can never flip what the user last saw.
    public private(set) var isFrozen = false

    public init() {}

    public var isLatched: Bool {
        if case .latched = state { return true }
        return false
    }

    /// Feeds one live classification of the utterance head. Fluid until a
    /// match: the list may open, show a failed attempt, recover on a retry, or
    /// collapse on a cancel, tracking the classifier. The first match latches
    /// for good. Returns true exactly when this call latched (chime moment).
    @discardableResult
    public mutating func apply(_ prefix: VoiceCommand.Prefix) -> Bool {
        guard !isFrozen, !isLatched else { return false }
        switch prefix {
        case .none: state = .inactive
        case .awaitingName: state = .awaitingName
        case .unmatched(let spoken): state = .unmatched(spoken: spoken)
        case .cancelled: state = .cancelled
        case .matched(let id, let name, _):
            // The live remainder is discarded — content always comes from the
            // final full-buffer transcript at release.
            state = .latched(profileID: id, profileName: name)
            return true
        }
        return false
    }

    /// Key release: the contract point. Whatever the pill shows now is the
    /// outcome, permanently.
    public mutating func freeze() { isFrozen = true }

    // MARK: - Release mapping

    /// What the take resolves to once the final transcript exists.
    public enum ReleaseOutcome: Equatable, Sendable {
        /// No command was ever shown live — the transcript is inserted
        /// verbatim, untouched, even if it happens to contain command words.
        case dictation(text: String)
        /// The latched profile runs on the command-stripped content.
        case switched(profileID: String, profileName: String, content: String)
        /// No switch; command words are stripped and the notice explains why.
        case kept(content: String, notice: KeptNotice?)

        public enum KeptNotice: Equatable, Sendable {
            /// A bare cancel — nothing left to insert.
            case cancelled
            /// Released while the list was still waiting for a name.
            case releasedEarly
            /// The spoken words (as the pill showed them) matched no profile.
            case unknownName(spoken: String)
        }
    }

    /// Maps the frozen decision onto the final transcript. The transcript
    /// contributes CONTENT only: the full grammar locates the command boundary
    /// to strip, and when the final decode garbled what the live pass had
    /// already confirmed, a relaxed re-match against the latched name alone
    /// recovers the boundary. It never selects or unselects a profile.
    public func releaseOutcome(
        transcript: String, trigger: String, cancelWords: [String],
        profiles: [(id: String, name: String)]
    ) -> ReleaseOutcome {
        if state == .inactive { return .dictation(text: transcript) }

        let resolution = VoiceCommand.resolve(
            transcript: transcript, trigger: trigger,
            cancelWords: cancelWords, profiles: profiles)
        let stripped = Self.strippedContent(resolution, full: transcript)

        switch state {
        case .inactive:
            return .dictation(text: transcript) // unreachable; guarded above
        case .latched(let id, let name):
            var content = stripped
            switch resolution {
            case .failed, .none:
                // The final decode lost the boundary the live pass saw
                // (garbled name or trigger). Recover it against the latched
                // name only — decode drift must never reach another profile.
                if let relaxed = VoiceCommand.relaxedRemainder(
                    transcript: transcript, trigger: trigger, latchedName: name) {
                    content = relaxed
                }
            case .switched, .cancelled:
                break // boundary found; whatever it matched, those were command words
            }
            return .switched(profileID: id, profileName: name, content: content)
        case .cancelled:
            return .kept(content: stripped, notice: stripped.isEmpty ? .cancelled : nil)
        case .awaitingName:
            return .kept(content: stripped, notice: .releasedEarly)
        case .unmatched(let spoken):
            // Echo the words the pill showed, not what the final decode heard.
            return .kept(content: stripped, notice: .unknownName(spoken: spoken))
        }
    }

    /// The transcript once the command region (as the final decode shows it)
    /// is removed — used whenever the live pass saw *some* command activity.
    private static func strippedContent(
        _ resolution: VoiceCommand.Resolution, full: String
    ) -> String {
        switch resolution {
        case .none: return full
        case .switched(let match): return match.remainder
        case .cancelled(let rest): return rest
        case .failed(_, let insert): return insert
        }
    }
}
