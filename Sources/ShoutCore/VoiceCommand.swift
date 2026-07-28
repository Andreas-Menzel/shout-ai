// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation

/// Grammar for a spoken profile-switch command at the start of a transcript —
/// e.g. "use profile summarize, here is the text" with trigger "use profile"
/// yields (Summarize, "here is the text").
///
/// Matching is case- and punctuation-insensitive and forgiving: a spoken name
/// that's a prefix of the profile's name matches ("professional" →
/// "Professional writing"), and a number selects by position ("use profile two"
/// / "use profile 2"). A failed first attempt can be corrected in the same
/// breath — the words after the trigger are rescanned within a short window
/// ("use profile zummarize… Summarize" still switches) — and a cancel word
/// abandons the command, returning the rest of the utterance to ordinary
/// dictation. The grammar only matches at the very start of an utterance, so a
/// mid-sentence "use profile" in ordinary dictation isn't hijacked.
///
/// In the app, SELECTION is live: `classifyPrefix` runs on interim decodes of
/// the utterance head while recording, and whatever `VoiceSwitchDecision` has
/// latched at key release is what runs — the pill's display is the contract.
/// `resolve` runs on the finished transcript only to locate the command
/// boundary for stripping (plus `relaxedRemainder` when the final decode
/// garbled what the live pass confirmed). Batch callers with no live feedback
/// (shout-cli) still use `resolve`/`parse` for selection.
public enum VoiceCommand {
    public struct Match: Equatable, Sendable {
        public let profileID: String
        public let profileName: String
        public let remainder: String
    }

    /// Release-time resolution of a transcript against the switch grammar.
    public enum Resolution: Equatable, Sendable {
        /// No leading trigger — the transcript is ordinary dictation.
        case none
        /// A profile was named (possibly after a corrected first attempt).
        case switched(Match)
        /// A cancel word abandoned the command; `remainder` is ordinary
        /// dictation for the unchanged active profile.
        case cancelled(remainder: String)
        /// The trigger was spoken but nothing matched. `spoken` is the first
        /// words heard after the trigger, for feedback (empty if none).
        /// `insert` is what should still be typed: empty when the utterance
        /// was only a botched command, else everything after the trigger —
        /// silently dropping real dictation is worse than keeping a couple of
        /// stray words. The trigger itself is never inserted.
        case failed(spoken: String, insert: String)
    }

    struct Token { let canonical: String; let end: String.Index }

    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, !s[i].isLetter, !s[i].isNumber { i = s.index(after: i) }
            guard i < s.endIndex else { break }
            let start = i
            while i < s.endIndex, s[i].isLetter || s[i].isNumber { i = s.index(after: i) }
            tokens.append(Token(canonical: s[start..<i].lowercased(), end: i))
        }
        return tokens
    }

    private static let numberWords = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    /// Splits a comma-separated phrase field into trimmed, non-empty phrases —
    /// "cancel, abbrechen" → ["cancel", "abbrechen"].
    public static func phraseList(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Resolves a finished transcript against the full switch grammar. In the
    /// app this does NOT select the profile — selection is live and frozen at
    /// key release (see `VoiceSwitchDecision`); here the result only locates
    /// the command region so the content can be stripped. It shares the same
    /// scanner as `classifyPrefix`, so the boundary it finds is the boundary
    /// the live pass saw. shout-cli, with no live feedback, still selects
    /// through this call.
    public static func resolve(
        transcript: String, trigger: String, cancelWords: [String] = [],
        profiles: [(id: String, name: String)]
    ) -> Resolution {
        let triggerTokens = tokenize(trigger).map { $0.canonical }
        guard !triggerTokens.isEmpty else { return .none }
        let tokens = tokenize(transcript)
        guard tokens.count >= triggerTokens.count else { return .none }
        // The trigger must sit at the very start.
        for (i, expected) in triggerTokens.enumerated() where tokens[i].canonical != expected {
            return .none
        }
        let after = Array(tokens[triggerTokens.count...])

        if let hit = scan(after, profiles: profiles, cancelWords: cancelWords) {
            switch hit {
            case .match(let id, let name, let end):
                return .switched(Match(profileID: id, profileName: name,
                                       remainder: remainder(transcript, after: end)))
            case .cancel(let end):
                // The user may immediately start over ("… cancel, use profile
                // summarize: …"), so the remainder gets a fresh resolution.
                let rest = remainder(transcript, after: end)
                let inner = resolve(transcript: rest, trigger: trigger,
                                    cancelWords: cancelWords, profiles: profiles)
                if case .none = inner { return .cancelled(remainder: rest) }
                return inner
            }
        }

        let spoken = after.prefix(2).map { $0.canonical }.joined(separator: " ")
        let insert = after.count <= Tuning.voiceCommandDropThresholdTokens
            ? ""
            : remainder(transcript, after: tokens[triggerTokens.count - 1].end)
        return .failed(spoken: spoken, insert: insert)
    }

    /// Live classification of a *growing* interim transcript, for pill feedback
    /// while the user is still speaking: nothing yet, trigger heard but no
    /// profile named (show the list), a profile matched (show it), the spoken
    /// words matching nothing (say so), or the command cancelled.
    public enum Prefix: Equatable, Sendable {
        case none
        case awaitingName
        case matched(profileID: String, profileName: String, remainder: String)
        /// The words after the trigger match nothing and can no longer grow
        /// into a name — show "isn't on the list" feedback.
        case unmatched(spoken: String)
        /// A cancel word was heard — collapse the list; dictation continues.
        case cancelled
    }

    public static func classifyPrefix(
        transcript: String, trigger: String, cancelWords: [String] = [],
        profiles: [(id: String, name: String)]
    ) -> Prefix {
        let triggerTokens = tokenize(trigger).map { $0.canonical }
        guard !triggerTokens.isEmpty else { return .none }
        let tokens = tokenize(transcript)
        // Trigger not fully spoken yet.
        guard tokens.count >= triggerTokens.count else { return .none }
        for (i, expected) in triggerTokens.enumerated() where tokens[i].canonical != expected {
            return .none
        }
        let after = Array(tokens[triggerTokens.count...])
        guard !after.isEmpty else { return .awaitingName }

        if let hit = scan(after, profiles: profiles, cancelWords: cancelWords) {
            switch hit {
            case .match(let id, let name, let end):
                return .matched(profileID: id, profileName: name,
                                remainder: remainder(transcript, after: end))
            case .cancel(let end):
                let rest = remainder(transcript, after: end)
                let inner = classifyPrefix(transcript: rest, trigger: trigger,
                                           cancelWords: cancelWords, profiles: profiles)
                if case .none = inner { return .cancelled }
                return inner
            }
        }

        if couldStillMatch(after, profiles: profiles) { return .awaitingName }
        return .unmatched(spoken: after.prefix(2).map { $0.canonical }.joined(separator: " "))
    }

    private enum ScanHit {
        case match(id: String, name: String, end: String.Index)
        case cancel(end: String.Index)
    }

    /// Scans the words after the trigger for the first thing that resolves the
    /// command: a position number, a profile name, or a cancel word. Only the
    /// first `Tuning.voiceCommandScanWindowTokens` starting positions are
    /// tried — that's what lets a corrected retry ("zummarize… Summarize")
    /// work while a name spoken deep inside ordinary dictation can't hijack
    /// the take. The leftmost hit wins; at the same position a profile beats a
    /// cancel word, so a profile literally named "Cancel" stays reachable.
    private static func scan(
        _ after: [Token],
        profiles: [(id: String, name: String)],
        cancelWords: [String]
    ) -> ScanHit? {
        let cancels = cancelWords.map { tokenize($0).map { $0.canonical } }.filter { !$0.isEmpty }
        for start in 0..<min(after.count, Tuning.voiceCommandScanWindowTokens) {
            // Number selection: "use profile 2" / "use profile two".
            if let n = numberValue(after[start].canonical), n >= 1, n <= profiles.count {
                let p = profiles[n - 1]
                return .match(id: p.id, name: p.name, end: after[start].end)
            }
            // Name selection: match the longest run of words from this position
            // against a profile's canonical name (exact, or the spoken name
            // being a prefix of the full one). Exact wins over prefix; longer
            // names win over shorter.
            var best: (id: String, name: String, end: String.Index, score: Int)?
            for n in 1...min(4, after.count - start) {
                let candidate = after[start..<start + n].map { $0.canonical }.joined()
                guard candidate.count >= 3 else { continue }
                for p in profiles {
                    let pCanon = tokenize(p.name).map { $0.canonical }.joined()
                    guard !pCanon.isEmpty else { continue }
                    let exact = candidate == pCanon
                    let spokenIsPrefix = pCanon.hasPrefix(candidate) && candidate.count >= 4
                    guard exact || spokenIsPrefix else { continue }
                    let score = (exact ? 1000 : 0) + pCanon.count
                    if best == nil || score > best!.score {
                        best = (p.id, p.name, after[start + n - 1].end, score)
                    }
                }
            }
            if let best {
                return .match(id: best.id, name: best.name, end: best.end)
            }
            // A cancel word abandons the command ("use profile… cancel").
            for cancel in cancels where after.count - start >= cancel.count {
                if after[start..<start + cancel.count].map({ $0.canonical }) == cancel {
                    return .cancel(end: after[start + cancel.count - 1].end)
                }
            }
        }
        return nil
    }

    /// Whether the tail of the utterance could still grow into a profile name —
    /// some run of words ending at the *last* token being a strict prefix of a
    /// name ("use profile su", or "use profile zummarize su" mid-retry). While
    /// true, the live UI keeps waiting instead of flagging a failed match the
    /// speaker is still finishing.
    private static func couldStillMatch(
        _ after: [Token], profiles: [(id: String, name: String)]
    ) -> Bool {
        let canons = profiles.map { tokenize($0.name).map { $0.canonical }.joined() }
        let firstStart = max(0, after.count - 4)
        let endStart = min(after.count, Tuning.voiceCommandScanWindowTokens)
        guard firstStart < endStart else { return false }
        for start in firstStart..<endStart {
            let candidate = after[start...].map { $0.canonical }.joined()
            if canons.contains(where: { $0.count > candidate.count && $0.hasPrefix(candidate) }) {
                return true
            }
        }
        return false
    }

    /// Best-effort strip when the final decode garbled a command the live pass
    /// had already confirmed: the selection is fixed (the pill showed it), so
    /// this only recovers the boundary. Scans the head of the transcript for
    /// the LATCHED profile's name alone — decode drift must never reach any
    /// other profile — accepting the strict rules' mirror image (spoken word
    /// carrying an inflection of the name, "summarized") and small typo
    /// distances ("zummarize"). Returns the remainder after the hit, or nil
    /// when even the relaxed match finds nothing (caller keeps the failed-path
    /// text rather than dropping content). Worst case of a false hit is a
    /// couple of command-adjacent words stripped from the content — bounded,
    /// unlike a wrong profile.
    static func relaxedRemainder(
        transcript: String, trigger: String, latchedName: String
    ) -> String? {
        let canon = tokenize(latchedName).map { $0.canonical }.joined()
        guard canon.count >= 3 else { return nil }
        let tokens = tokenize(transcript)
        // The command lives in the first trigger-plus-window tokens; the
        // trigger itself may be garbled, so every start position is tried.
        let limit = min(tokens.count, tokenize(trigger).count + Tuning.voiceCommandScanWindowTokens)
        for start in 0..<limit {
            // Longest run first, so a multi-word name isn't cut after word one.
            for n in stride(from: min(4, tokens.count - start), through: 1, by: -1) {
                let candidate = tokens[start..<start + n].map { $0.canonical }.joined()
                guard candidate.count >= 3 else { continue }
                let exact = candidate == canon
                let spokenIsPrefix = canon.hasPrefix(candidate) && candidate.count >= 4
                // The fuzzy rules are word-level phenomena and stay on single
                // tokens: over multi-token joins, a garbage token glued to the
                // name ("ff"+"summarize") would sneak inside the edit limit.
                let singleWord = n == 1
                // Inflection: the name plus a short suffix ("summarized").
                let inflected = singleWord
                    && candidate.hasPrefix(canon) && candidate.count <= canon.count + 3
                let typo = singleWord && candidate.count >= 4
                    && withinEditDistance(candidate, canon, limit: canon.count >= 6 ? 2 : 1)
                if exact || spokenIsPrefix || inflected || typo {
                    return remainder(transcript, after: tokens[start + n - 1].end)
                }
            }
        }
        return nil
    }

    /// Bounded Levenshtein check — true when the strings are within `limit`
    /// edits. Early-outs on length difference; the inputs are short canonical
    /// words, so the plain two-row DP is plenty.
    private static func withinEditDistance(_ a: String, _ b: String, limit: Int) -> Bool {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if abs(x.count - y.count) > limit { return false }
        // The `1...count` loops below trap on an empty input. Callers today always
        // pass ≥3 scalars, so this guard is insurance against a future caller
        // rather than a live bug — an empty word is trivially within `limit` of
        // another only if that one is short enough.
        guard !x.isEmpty, !y.isEmpty else { return max(x.count, y.count) <= limit }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var row = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                let sub = prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)
                row[j] = min(sub, prev[j] + 1, row[j - 1] + 1)
            }
            if row.min()! > limit { return false }
            prev = row
        }
        return prev[y.count] <= limit
    }

    /// Compatibility form of `resolve` for callers that only care about a
    /// completed switch (shout-cli, older tests): the matched profile, or nil.
    public static func parse(transcript: String, trigger: String,
                             profiles: [(id: String, name: String)]) -> Match? {
        if case .switched(let m) = resolve(transcript: transcript, trigger: trigger,
                                           cancelWords: [], profiles: profiles) {
            return m
        }
        return nil
    }

    private static func numberValue(_ s: String) -> Int? {
        Int(s) ?? numberWords[s]
    }

    /// The transcript after the consumed command, with only *leading* whitespace
    /// and punctuation trimmed — a trailing "?" the speaker dictated must survive.
    private static func remainder(_ transcript: String, after end: String.Index) -> String {
        var r = transcript[end...]
        while let first = r.first, first.isWhitespace || first.isPunctuation { r = r.dropFirst() }
        return String(r)
    }
}
