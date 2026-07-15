// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import Foundation

/// Deterministic, meaning-preserving cleanup applied to the final text just
/// before insertion — independent of the LLM rewrite, so it also runs when the
/// rewrite is disabled, skipped (too few words), or unavailable.
///
/// Two jobs:
///  1. Glossary normalization — force product/proper names to their canonical
///     spelling regardless of how Whisper cased or split them. Whisper's
///     `initial_prompt` only *biases* recognition; it cannot preserve
///     camelCase or no-space compounds, so "HTTPServer" comes back as "HTTP
///     Server". This fixes that deterministically.
///  2. A very conservative hesitation strip. Deliberately tiny: only sounds
///     that are not real words in German or English. Ambiguous discourse
///     markers ("also", "genau", "like", "well") and the German preposition
///     "um" are left to the meaning-aware rewrite.
public enum TextNormalizer {
    public static func normalize(_ text: String, glossary: [String]) -> String {
        applyGlossary(stripFillers(text), glossary: glossary)
    }

    // MARK: - Glossary

    /// Rewrites any case-/space-insensitive surface form of a glossary term to
    /// its exact canonical spelling, anchored on word boundaries so it never
    /// matches inside a larger word.
    public static func applyGlossary(_ text: String, glossary: [String]) -> String {
        guard !text.isEmpty else { return text }
        // Longest first: a short term ("HTTP") must not consume part of a longer
        // one ("HTTPServer") before the longer one gets a chance to match.
        let terms = glossary
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        var result = text
        for term in terms {
            let parts = wordParts(of: term)
            guard !parts.isEmpty else { continue }
            // e.g. ["HTTP","Server"] -> \bHTTP\s*Server\b  (matches "HTTPServer",
            // "HTTP Server", "http   server", …). \s* also matches zero spaces.
            let pattern = "\\b"
                + parts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s*")
                + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let template = NSRegularExpression.escapedTemplate(for: term)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    /// Splits a compound identifier into its constituent words, handling
    /// camelCase, PascalCase, ALLCAPS acronym runs, digit transitions, and
    /// explicit separators (space, hyphen, underscore).
    ///
    ///   "openSOURCE" -> ["open", "SOURCE"]
    ///   "HTTPServer" -> ["HTTP", "Server"]
    ///   "CameraGPS"  -> ["Camera", "GPS"]
    ///   "XMLReader"  -> ["XML", "Reader"]
    public static func wordParts(of term: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let chars = Array(term)
        for (i, ch) in chars.enumerated() {
            guard ch.isLetter || ch.isNumber else {
                // Separator: end the current word, drop the character.
                if !current.isEmpty { parts.append(current); current = "" }
                continue
            }
            if !current.isEmpty {
                let prev = chars[i - 1]
                let startsNewWord =
                    // lower/digit -> Upper  (camelCase)
                    (ch.isUppercase && !prev.isUppercase)
                    // Upper -> Upper followed by lower  (end of an acronym run)
                    || (ch.isUppercase && prev.isUppercase && i + 1 < chars.count && chars[i + 1].isLowercase)
                    // letter <-> digit transition
                    || (ch.isNumber != prev.isNumber)
                if startsNewWord { parts.append(current); current = "" }
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// The canonical term rendered as separate, space-joined words — the shape
    /// Whisper is most likely to emit. Used to build a realistic few-shot
    /// example for the rewrite prompt. "HTTPServer" -> "HTTP Server".
    public static func spacedForm(of term: String) -> String {
        let parts = wordParts(of: term)
        return parts.isEmpty ? term : parts.joined(separator: " ")
    }

    // MARK: - Fillers

    /// Pure hesitation sounds that are not real words in German or English.
    /// Intentionally excludes "um" (German "um zehn Uhr"), "hm"/"mhm", and all
    /// discourse markers — those need sentence context the rewrite has.
    static let fillers: Set<String> = [
        "äh", "ähm", "ähem", "ähhm", "öh", "öhm",
        "uh", "uhh", "uhm", "umm", "erm",
    ]

    /// Removes standalone hesitation tokens (with an optional trailing comma)
    /// and repairs the spacing/punctuation the removal leaves behind.
    public static func stripFillers(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let alternation = fillers
            .sorted { $0.count > $1.count } // longest first, e.g. "ähm" before "äh"
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // Eat any whitespace before the token so "das äh Update" -> "das Update".
        let pattern = "\\s*\\b(?:\(alternation))\\b,?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return tidySpacing(stripped)
    }

    /// Collapses doubled horizontal whitespace, removes space before
    /// punctuation, caps runaway blank lines, and trims stray leading
    /// punctuation/space left by token removal. Line breaks are preserved: the
    /// markdown structure a rewrite emits (headings, lists, blank-line paragraph
    /// breaks) lives in the newlines, so a plain `\s` collapse — which also eats
    /// `\n` — would weld separate blocks onto one line.
    static func tidySpacing(_ text: String) -> String {
        var t = text
        // `[^\S\r\n]` is "whitespace except line breaks" — spaces and tabs only.
        t = t.replacingOccurrences(of: #"[^\S\r\n]{2,}"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[^\S\r\n]+([,.;:!?])"#, with: "$1", options: .regularExpression)
        // Never leave more than one blank line between blocks.
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^[\s,]+"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
