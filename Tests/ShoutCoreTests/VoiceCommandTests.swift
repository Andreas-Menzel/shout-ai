// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andreas Menzel

import XCTest
@testable import ShoutCore

final class VoiceCommandTests: XCTestCase {
    private let profiles: [(id: String, name: String)] = [
        ("builtin-cleanup", "Clean-up"),
        ("builtin-professional", "Professional writing"),
        ("builtin-prompt-engineer", "Prompt engineer"),
        ("builtin-summarize", "Summarize"),
        ("builtin-translate-en", "Translate → English"),
    ]

    private func parse(_ transcript: String, trigger: String = "use profile") -> VoiceCommand.Match? {
        VoiceCommand.parse(transcript: transcript, trigger: trigger, profiles: profiles)
    }

    func testNoTriggerReturnsNil() {
        XCTAssertNil(parse("just clean this up please"))
    }

    func testTriggerMidSentenceIgnored() {
        // Only honored at the very start, so ordinary content isn't hijacked.
        XCTAssertNil(parse("please use profile summarize this"))
    }

    func testExactNameWithRemainder() {
        let m = parse("use profile summarize the update is out and stable")
        XCTAssertEqual(m?.profileID, "builtin-summarize")
        XCTAssertEqual(m?.remainder, "the update is out and stable")
    }

    func testPureSwitchNoRemainder() {
        let m = parse("use profile summarize")
        XCTAssertEqual(m?.profileID, "builtin-summarize")
        XCTAssertEqual(m?.remainder, "")
    }

    func testSpokenNameIsPrefixOfFullName() {
        let m = parse("use profile professional here is my draft")
        XCTAssertEqual(m?.profileID, "builtin-professional")
        XCTAssertEqual(m?.remainder, "here is my draft")
    }

    func testMultiWordNameCollapsesSpacingAndHyphen() {
        let m = parse("use profile clean up machen wir das, oder?")
        XCTAssertEqual(m?.profileID, "builtin-cleanup")
        XCTAssertEqual(m?.remainder, "machen wir das, oder?")   // trailing question preserved
    }

    func testNumberSelectionDigitAndWord() {
        XCTAssertEqual(parse("use profile 4 blah blah")?.profileID, "builtin-summarize")
        XCTAssertEqual(parse("use profile two here we go")?.profileID, "builtin-professional")
    }

    func testCaseAndPunctuationInsensitive() {
        let m = parse("Use profile, Summarize. Here is the text.")
        XCTAssertEqual(m?.profileID, "builtin-summarize")
        XCTAssertEqual(m?.remainder, "Here is the text.")
    }

    func testTranslatePrefixMatch() {
        let m = parse("use profile translate hallo welt")
        XCTAssertEqual(m?.profileID, "builtin-translate-en")
        XCTAssertEqual(m?.remainder, "hallo welt")
    }

    func testUnknownNameReturnsNil() {
        XCTAssertNil(parse("use profile xyzzy do the thing"))
    }

    func testToleratesHeavyPunctuation() {
        // Punctuation anywhere in/around the command is stripped for matching;
        // only leading punctuation is trimmed off the remainder (trailing kept).
        let m = parse("Use profile: summarize!! Here we go...")
        XCTAssertEqual(m?.profileID, "builtin-summarize")
        XCTAssertEqual(m?.remainder, "Here we go...")
    }

    func testTriggerAloneWithoutNameReturnsNil() {
        XCTAssertNil(parse("use profile"))
    }

    func testCustomTriggerPhrase() {
        let m = VoiceCommand.parse(transcript: "switch to summarize now please",
                                   trigger: "switch to", profiles: profiles)
        XCTAssertEqual(m?.profileID, "builtin-summarize")
        XCTAssertEqual(m?.remainder, "now please")
    }

    // MARK: - classifyPrefix (live interim feedback)

    private func classify(_ transcript: String) -> VoiceCommand.Prefix {
        VoiceCommand.classifyPrefix(transcript: transcript, trigger: "use profile", profiles: profiles)
    }

    func testClassifyNoneBeforeTrigger() {
        XCTAssertEqual(classify("hello world"), .none)
        XCTAssertEqual(classify("use"), .none)   // trigger not fully spoken
    }

    func testClassifyAwaitingNameWhenTriggerButNoMatch() {
        XCTAssertEqual(classify("use profile"), .awaitingName)          // trigger only
        XCTAssertEqual(classify("use profile sum"), .awaitingName)      // 3-char partial, below prefix threshold
    }

    func testClassifyMatchesFourCharPrefix() {
        // A 4-char prefix is enough to lock in a match (fast, no collisions among built-ins).
        guard case .matched(_, let name, _) = classify("use profile summ") else {
            return XCTFail("expected matched")
        }
        XCTAssertEqual(name, "Summarize")
    }

    func testClassifyMatched() {
        guard case .matched(_, let name, let remainder) = classify("use profile summarize the rest") else {
            return XCTFail("expected matched")
        }
        XCTAssertEqual(name, "Summarize")
        XCTAssertEqual(remainder, "the rest")
    }

    // MARK: - resolve (release-time resolution: retry window, cancel, failure)

    private func resolve(_ transcript: String, trigger: String = "use profile",
                         cancelWords: [String] = ["cancel", "abbrechen"]) -> VoiceCommand.Resolution {
        VoiceCommand.resolve(transcript: transcript, trigger: trigger,
                             cancelWords: cancelWords, profiles: profiles)
    }

    func testResolveNoTriggerIsNone() {
        XCTAssertEqual(resolve("just clean this up please"), .none)
        XCTAssertEqual(resolve("please use profile summarize this"), .none)   // mid-sentence
    }

    func testResolveAgreesWithParseOnFirstWordMatch() {
        guard case .switched(let m) = resolve("use profile summarize the update is out") else {
            return XCTFail("expected switched")
        }
        XCTAssertEqual(m, parse("use profile summarize the update is out"))
    }

    func testResolveTriggerAloneIsFailedEmpty() {
        XCTAssertEqual(resolve("use profile"), .failed(spoken: "", insert: ""))
    }

    func testResolveUnknownShortInsertsNothing() {
        // ≤ 2 words after the trigger: a botched command, not content.
        XCTAssertEqual(resolve("use profile xyzzy"), .failed(spoken: "xyzzy", insert: ""))
        XCTAssertEqual(resolve("use profile zummarize bitte"),
                       .failed(spoken: "zummarize bitte", insert: ""))
    }

    func testResolveUnknownLongKeepsTextAfterTrigger() {
        // Real dictation after a failed attempt survives, original casing intact;
        // only the trigger itself is stripped.
        XCTAssertEqual(resolve("Use profile blorp send the Invoice today"),
                       .failed(spoken: "blorp send", insert: "blorp send the Invoice today"))
    }

    func testRescanRecoversAfterGarbage() {
        guard case .switched(let m) = resolve("use profile xyzzy summarize the text") else {
            return XCTFail("expected switched")
        }
        XCTAssertEqual(m.profileID, "builtin-summarize")
        XCTAssertEqual(m.remainder, "the text")
    }

    func testRescanLeftmostMatchWins() {
        guard case .switched(let m) = resolve("use profile clean summarize x") else {
            return XCTFail("expected switched")
        }
        XCTAssertEqual(m.profileID, "builtin-cleanup")
    }

    func testNoMatchBeyondScanWindow() {
        // The name sits past the 6-word window — ordinary dictation, no hijack.
        XCTAssertEqual(resolve("use profile aa bb cc dd ee ff summarize it"),
                       .failed(spoken: "aa bb",
                               insert: "aa bb cc dd ee ff summarize it"))
    }

    func testNumberRetryWithinWindow() {
        guard case .switched(let m) = resolve("use profile xyzzy two hello there") else {
            return XCTFail("expected switched")
        }
        XCTAssertEqual(m.profileID, "builtin-professional")
        XCTAssertEqual(m.remainder, "hello there")
    }

    func testOutOfRangeNumberFails() {
        XCTAssertEqual(resolve("use profile 9 hello"), .failed(spoken: "9 hello", insert: ""))
    }

    func testOutOfRangeNumberThenNameRecovers() {
        guard case .switched(let m) = resolve("use profile 9 summarize go") else {
            return XCTFail("expected switched")
        }
        XCTAssertEqual(m.profileID, "builtin-summarize")
        XCTAssertEqual(m.remainder, "go")
    }

    // MARK: - Cancel word

    func testCancelAloneAfterTrigger() {
        XCTAssertEqual(resolve("use profile cancel"), .cancelled(remainder: ""))
    }

    func testCancelStripsCommandAndKeepsRemainder() {
        XCTAssertEqual(resolve("use profile, cancel — hallo welt"),
                       .cancelled(remainder: "hallo welt"))
    }

    func testGermanCancelWordAfterFailedAttempt() {
        XCTAssertEqual(resolve("use profile äh abbrechen hallo welt"),
                       .cancelled(remainder: "hallo welt"))
    }

    func testMultiWordCancelPhrase() {
        let r = VoiceCommand.resolve(transcript: "use profile never mind hello",
                                     trigger: "use profile",
                                     cancelWords: ["never mind"], profiles: profiles)
        XCTAssertEqual(r, .cancelled(remainder: "hello"))
    }

    func testProfileNamedCancelBeatsCancelWord() {
        let withCancel = profiles + [("custom-cancel", "Cancel")]
        let r = VoiceCommand.resolve(transcript: "use profile cancel the meeting",
                                     trigger: "use profile",
                                     cancelWords: ["cancel"], profiles: withCancel)
        guard case .switched(let m) = r else { return XCTFail("expected switched") }
        XCTAssertEqual(m.profileID, "custom-cancel")
        XCTAssertEqual(m.remainder, "the meeting")
    }

    func testCancelBeyondWindowIsOrdinaryDictation() {
        let r = resolve("use profile aa bb cc dd ee ff cancel it")
        guard case .failed = r else { return XCTFail("expected failed, got \(r)") }
    }

    func testRetriggerAfterCancelSwitches() {
        guard case .switched(let m) =
                resolve("use profile xyzzy cancel use profile summarize hello") else {
            return XCTFail("expected switched")
        }
        XCTAssertEqual(m.profileID, "builtin-summarize")
        XCTAssertEqual(m.remainder, "hello")
    }

    func testCustomTriggerAndCancelWords() {
        let r = VoiceCommand.resolve(transcript: "Profil wechseln egal vergiss es weiter im Text",
                                     trigger: "Profil wechseln",
                                     cancelWords: ["vergiss es"], profiles: profiles)
        XCTAssertEqual(r, .cancelled(remainder: "weiter im Text"))
    }

    // MARK: - classifyPrefix: unmatched + cancelled feedback

    private func classifyWithCancel(_ transcript: String) -> VoiceCommand.Prefix {
        VoiceCommand.classifyPrefix(transcript: transcript, trigger: "use profile",
                                    cancelWords: ["cancel", "abbrechen"], profiles: profiles)
    }

    func testClassifyUnmatchedWhenNothingFits() {
        XCTAssertEqual(classify("use profile xyzzy"), .unmatched(spoken: "xyzzy"))
    }

    func testClassifyStrictPrefixStaysAwaiting() {
        // "pro" could still become "Professional writing" / "Prompt engineer".
        XCTAssertEqual(classify("use profile pro"), .awaitingName)
    }

    func testClassifyExtendableRetryTailStaysAwaiting() {
        // Mid-retry: the last word may still grow into a name.
        XCTAssertEqual(classify("use profile xyzzy su"), .awaitingName)
    }

    func testClassifyRetryGarbageIsUnmatched() {
        XCTAssertEqual(classify("use profile xyzzy some"), .unmatched(spoken: "xyzzy some"))
    }

    func testClassifyRecoversToMatchedAfterGarbage() {
        guard case .matched(_, let name, _) = classify("use profile xyzzy summarize") else {
            return XCTFail("expected matched")
        }
        XCTAssertEqual(name, "Summarize")
    }

    func testClassifyCancelledCollapses() {
        XCTAssertEqual(classifyWithCancel("use profile cancel"), .cancelled)
        XCTAssertEqual(classifyWithCancel("use profile abbrechen hallo welt"), .cancelled)
    }

    func testClassifyCancelThenRetriggerReopensList() {
        XCTAssertEqual(classifyWithCancel("use profile xyzzy cancel use profile"), .awaitingName)
    }

    // MARK: - phraseList

    func testPhraseListSplitsTrimsAndDropsEmpties() {
        XCTAssertEqual(VoiceCommand.phraseList(" cancel, abbrechen , ,never mind,"),
                       ["cancel", "abbrechen", "never mind"])
        XCTAssertEqual(VoiceCommand.phraseList(""), [])
    }
}
